// Run the direct N-body calculation on CUDA, with one thread per body.
#include <cuda_runtime.h>
#include "nbody/benchmark.hpp"
#include <cmath>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>

namespace {
constexpr unsigned int TILE_SIZE = 16;
struct Vector { double x, y, z; };
struct Body {
    Vector position, velocity;
    double mass;
};

__global__
void calculate_acceleration_tiled(
    const Body* bodies,
    Vector* acceleration,
    unsigned int count,
    double gravity,
    double softening_squared
) {
    // Shared memory containing complete Body structures
    // The body whose acceleration we want to calculate
    __shared__ Body target_tile[TILE_SIZE];
    __shared__ Body source_tile[TILE_SIZE];

    // Thread coordinates inside the block
    const unsigned int tx = threadIdx.x;
    const unsigned int ty = threadIdx.y;

    // Global target and source indices
    const unsigned int i = blockIdx.x * TILE_SIZE + tx;
    const unsigned int j = blockIdx.y * TILE_SIZE + ty;

    // Load target bodies: one thread per target
    if (ty == 0 && i < count) {
        target_tile[tx] = bodies[i];
    }

    // Load source bodies: one thread per source
    if (tx == 0 && j < count) {
        source_tile[ty] = bodies[j];
    }

    // Wait until both tiles are loaded
    __syncthreads();

    // Calculate interaction between target i and source j
    if (i < count && j < count && i != j) {

        const Vector target = target_tile[tx].position;
        const Body source = source_tile[ty];

        const double dx = source.position.x - target.x;
        const double dy = source.position.y - target.y;
        const double dz = source.position.z - target.z;

        const double r2 =
            dx * dx + dy * dy + dz * dz + softening_squared;

        if (r2 > 0.0 && isfinite(r2)) {

            const double inverse_r = 1.0 / sqrt(r2);

            const double factor =
                gravity * source.mass *
                inverse_r * inverse_r * inverse_r;

            const double ax = factor * dx;
            const double ay = factor * dy;
            const double az = factor * dz;

            // Accumulate contributions from different source tiles
            atomicAdd(&acceleration[i].x, ax);
            atomicAdd(&acceleration[i].y, ay);
            atomicAdd(&acceleration[i].z, az);
        }
    }
}

class GpuSimulation {

public:
    GpuSimulation(unsigned int count, nbody::Parameters physics)
        : count_(count),
        block_size_(TILE_SIZE, TILE_SIZE),
        grid_size_(
            (count + TILE_SIZE - 1) / TILE_SIZE,
            (count + TILE_SIZE - 1) / TILE_SIZE
        ),
        physics_(physics),
        bodies_(device_buffer<Body>(count)),
        acceleration_(device_buffer<Vector>(count)),
        host_(host_buffer(count))
    {}

    ~GpuSimulation() {
        cudaStreamSynchronize(nullptr);
    }

    // Total number of 2D acceleration blocks
    unsigned int grid_size() const {
        return grid_size_.x * grid_size_.y;
    }

    // Prepare initial data
    void prepare(const nbody::State& state) {

        for (unsigned int i = 0; i < count_; ++i) {

            host_[i] = {
                {state.x[i], state.y[i], state.z[i]},
                {state.vx[i], state.vy[i], state.vz[i]},
                state.mass[i]
            };
        }
    }

    // Upload data to GPU
    void upload() {

        check_cuda(
            cudaMemcpyAsync(
                bodies_.get(),
                // points to the pinned memory
                host_.get(),
                sizeof(Body) * count_,
                cudaMemcpyHostToDevice
            ),
            "Copy initial state to GPU"
        );

        update_acceleration();
    }

   // Advance simulation
    void advance(std::uint64_t steps) {
        for (std::uint64_t step = 0; step < steps; ++step) {

            kick_and_drift<<<grid_size_.x, block_size_.x>>>(
                bodies_.get(), acceleration_.get(), count_, physics_.dt
            );

            check_cuda(cudaGetLastError(), "Launch kick and drift");

            update_acceleration();

            finish_kick<<<grid_size_.x, block_size_.x>>>(
                bodies_.get(), acceleration_.get(), count_,
                0.5 * physics_.dt
            );

            check_cuda(cudaGetLastError(), "Launch final kick");
        }
    }

    // Download results
    void download() {

        check_cuda(
            cudaMemcpyAsync(
                host_.get(),
                bodies_.get(),
                sizeof(Body) * count_,
                cudaMemcpyDeviceToHost
            ),
            "Copy state back to host"
        );
    }

    // Calculate energy

    double energy(nbody::State& state) const {

        for (unsigned int i = 0; i < count_; ++i) {

            const auto& body = host_[i];

            state.x[i] = body.position.x;
            state.y[i] = body.position.y;
            state.z[i] = body.position.z;

            state.vx[i] = body.velocity.x;
            state.vy[i] = body.velocity.y;
            state.vz[i] = body.velocity.z;

            state.mass[i] = body.mass;
        }

        return nbody::diagnostics(state, physics_).total_energy();
    }

private:

    // Update acceleration using the 2D tiled kernel

    void update_acceleration() {

        check_cuda(
            cudaMemsetAsync(acceleration_.get(), 0,
                            sizeof(Vector) * count_),
            "Initialize acceleration"
        );

        calculate_acceleration_tiled<<<grid_size_, block_size_>>>(
            bodies_.get(),
            acceleration_.get(),
            count_,
            physics_.gravitational_constant,
            physics_.softening * physics_.softening
        );

        check_cuda(cudaGetLastError(), "Launch acceleration calculation");
    }
    // Members
    unsigned int count_;

    dim3 block_size_;
    dim3 grid_size_;

    nbody::Parameters physics_;

    std::unique_ptr<Body, decltype(&cudaFree)> bodies_;
    std::unique_ptr<Vector, decltype(&cudaFree)> acceleration_;
    std::unique_ptr<Body[], decltype(&cudaFreeHost)> host_;
};

} // namespace

