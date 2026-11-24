// Houda's CUDA force calculation with 2D tiles and GPU integration.
#include <cuda_runtime.h>
#include "benchmark.hpp"
#include <algorithm>
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

__device__ void add_acceleration(double* component, double contribution) {
#if defined(__CUDA_ARCH__) && __CUDA_ARCH__ < 600
    // Older CUDA targets need a compare-and-swap for double precision.
    auto* bits = reinterpret_cast<unsigned long long*>(component);
    auto previous = atomicCAS(bits, 0ULL, 0ULL);
    unsigned long long expected;
    do {
        expected = previous;
        const double sum = __longlong_as_double(expected) + contribution;
        previous = atomicCAS(bits, expected, __double_as_longlong(sum));
    } while (previous != expected);
#else
    atomicAdd(component, contribution);
#endif
}

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
            add_acceleration(&acceleration[i].x, ax);
            add_acceleration(&acceleration[i].y, ay);
            add_acceleration(&acceleration[i].z, az);
        }
    }
}

__global__ void kick_and_drift(Body* bodies, const Vector* acceleration, unsigned int count, double dt) {
    const auto i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= count) return;

    const double half_dt = 0.5 * dt;
    auto& body = bodies[i];
    body.velocity.x += half_dt * acceleration[i].x;
    body.velocity.y += half_dt * acceleration[i].y;
    body.velocity.z += half_dt * acceleration[i].z;
    body.position.x += dt * body.velocity.x;
    body.position.y += dt * body.velocity.y;
    body.position.z += dt * body.velocity.z;
}

__global__ void finish_kick(Body* bodies, const Vector* acceleration, unsigned int count, double half_dt) {
    const auto i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= count) return;

    bodies[i].velocity.x += half_dt * acceleration[i].x;
    bodies[i].velocity.y += half_dt * acceleration[i].y;
    bodies[i].velocity.z += half_dt * acceleration[i].z;
}

void check_cuda(cudaError_t error, const char* operation) {
    if (error != cudaSuccess)
        throw std::runtime_error(std::string(operation) + ": " + cudaGetErrorString(error));
}

template <typename T>
auto device_buffer(unsigned int count) {
    T* buffer = nullptr;
    check_cuda(cudaMalloc(&buffer, sizeof(T) * count), "Allocate GPU memory");
    return std::unique_ptr<T, decltype(&cudaFree)>(buffer, cudaFree);
}

auto host_buffer(unsigned int count) {
    Body* buffer = nullptr;
    check_cuda(cudaMallocHost(&buffer, sizeof(Body) * count), "Allocate pinned host memory");
    std::uninitialized_default_construct_n(buffer, count);
    return std::unique_ptr<Body[], decltype(&cudaFreeHost)>(buffer, cudaFreeHost);
}

class Event {
public:
    Event() { check_cuda(cudaEventCreate(&event_), "Create CUDA event"); }
    ~Event() { cudaEventDestroy(event_); }
    Event(const Event&) = delete;
    Event& operator=(const Event&) = delete;

    void record() const { check_cuda(cudaEventRecord(event_), "Record CUDA event"); }
    void wait() const { check_cuda(cudaEventSynchronize(event_), "Wait for CUDA event"); }
    double seconds_since(const Event& start) const {
        float ms = 0;
        check_cuda(cudaEventElapsedTime(&ms, start.event_, event_), "Read CUDA event time");
        return ms / 1000.0;
    }

private:
    cudaEvent_t event_ = nullptr;
};

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

    }

    void initialize_acceleration() {
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

int main(int argc, char** argv) {
    using namespace nbody;
    try {
        const auto options = parse_options(argc, argv, true);
        if (options.block_size != TILE_SIZE * TILE_SIZE)
            throw std::invalid_argument("gpu-optim uses 16 x 16 tiles. Set --block-size 256.");
        int device = 0;
        int max_threads = 0;
        check_cuda(cudaGetDevice(&device), "Select a CUDA device");
        check_cuda(cudaDeviceGetAttribute(&max_threads, cudaDevAttrMaxThreadsPerBlock, device),
                   "Read the device block size limit");
        if (options.block_size > static_cast<unsigned int>(max_threads))
            throw std::invalid_argument("Block size exceeds the limit of this GPU.");

        const auto initial = make_initial_conditions(options.initial, options.physics);
        EnergyReport report(diagnostics(initial.state, options.physics).total_energy());

        GpuSimulation simulation(static_cast<unsigned int>(initial.state.size()), options.physics);
        simulation.prepare(initial.state);
        State checkpoint(initial.state.size());
        Timings timings;
        Event gpu_start, compute_start, compute_end;
        gpu_start.record();
        simulation.upload();
        compute_start.record();
        simulation.initialize_acceleration();

        const auto interval = options.energy_every == 0 ? options.steps : options.energy_every;
        for (std::uint64_t step = 0; step < options.steps;) {
            const auto batch = std::min(interval, options.steps - step);
            if (step != 0) compute_start.record();
            simulation.advance(batch);
            compute_end.record();
            compute_end.wait();
            const double compute = compute_end.seconds_since(compute_start);
            timings.compute += compute;
            timings.with_transfer += step == 0 ? compute_end.seconds_since(gpu_start) : compute;

            // We check this run's state after stopping the timer.
            simulation.download();
            check_cuda(cudaStreamSynchronize(nullptr), "Wait for the energy checkpoint");
            report.observe(simulation.energy(checkpoint));
            step += batch;
        }
        return print_benchmark("gpu-optim", options, timings, report);
    } catch (const std::exception& error) {
        std::cerr << "nbody_gpu_optim: " << error.what() << '\n';
        return 1;
    }
}
