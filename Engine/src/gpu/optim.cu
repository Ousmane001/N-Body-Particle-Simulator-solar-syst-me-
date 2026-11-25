#include <cuda_runtime.h>
#include "benchmark.hpp"
#include "gpu.hpp"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using Vector = nbody::Vec3;

struct DevicePhysics {
    double gravitational_constant;
    double softening_squared;
    double dt;
};

struct KernelConfig {
    unsigned int tile_size = 256;
    unsigned int block_size = 256;
    unsigned int grid_size = 0; // 0 means automatic
};

struct DeviceState {
    double* x;
    double* y;
    double* z;
    double* vx;
    double* vy;
    double* vz;
    double* mass;
};
// In the constant memory
__constant__ DevicePhysics physics_const;

// 2. CUDA error handling and memory allocation

void check_cuda(cudaError_t error, const char* operation) {
    if (error != cudaSuccess) {
        throw std::runtime_error(
            std::string(operation) + ": " +
            cudaGetErrorString(error)
        );
    }
}

template <typename T>
auto device_buffer(unsigned int count) {
    T* buffer = nullptr;

    check_cuda(
        cudaMalloc(&buffer, sizeof(T) * count),
        "Allocate GPU memory"
    );

    return std::unique_ptr<T, decltype(&cudaFree)>(
        buffer, cudaFree
    );
}

// 3. 1D tiled acceleration kernel

__global__ void calculate_acceleration_tiled(
    const DeviceState bodies,
    Vector* acceleration,
    unsigned int count,
    unsigned int tile_size
) {
    // Dynamic shared memory:
    // [sx | sy | sz | sm]
    extern __shared__ double shared[];

    double* sx = shared;
    double* sy = sx + tile_size;
    double* sz = sy + tile_size;
    double* sm = sz + tile_size;

    const unsigned int tid = threadIdx.x;

    // One thread computes the acceleration of one target body.
    const unsigned int i =
        blockIdx.x * blockDim.x + tid;

    const bool valid = i < count;

    // Load target body's position.
    double xi = 0.0;
    double yi = 0.0;
    double zi = 0.0;

    if (valid) {
        xi = bodies.x[i];
        yi = bodies.y[i];
        zi = bodies.z[i];
    }

    // Local acceleration accumulator.
    double ax = 0.0;
    double ay = 0.0;
    double az = 0.0;

    bool invalid_interaction = false;

    // Iterate over all source bodies, tile by tile.
    for (unsigned int base = 0; base < count; base += tile_size) {
        // This also works when tile_size != blockDim.x.
        for (unsigned int k = tid; k < tile_size; k += blockDim.x) {
            const unsigned int j = base + k;
            if (j < count) {
                sx[k] = bodies.x[j];
                sy[k] = bodies.y[j];
                sz[k] = bodies.z[j];
                sm[k] = bodies.mass[j];
            } else {
                sx[k] = 0.0;
                sy[k] = 0.0;
                sz[k] = 0.0;
                sm[k] = 0.0;
            }
        }
        // Wait until the complete tile is loaded.
        __syncthreads();

        // Each thread processes the loaded source tile
        if (valid && !invalid_interaction) {
            for (unsigned int k = 0; k < tile_size; ++k) {

                const unsigned int j = base + k;
                if (j >= count || j == i) {
                    continue;
                }
                const double dx = sx[k] - xi;
                const double dy = sy[k] - yi;
                const double dz = sz[k] - zi;

                const double r2 =
                    dx * dx +
                    dy * dy +
                    dz * dz +
                    physics_const.softening_squared;

                if (!(r2 > 0.0) || !isfinite(r2)) {
                    invalid_interaction = true;
                    break;
                }

                const double inverse_r = 1.0 / sqrt(r2);

                const double factor =
                    physics_const.gravitational_constant * sm[k] *
                    inverse_r * inverse_r * inverse_r;

                ax += factor * dx;
                ay += factor * dy;
                az += factor * dz;
            }
        }
        // All threads must finish reading the tile before
        __syncthreads();
    }

    // Write one acceleration per target body.
    if (valid) {
        if (invalid_interaction) {
            const double invalid = nan("");

            acceleration[i] = {
                invalid, invalid, invalid
            };
        } else {
            acceleration[i] = {ax, ay, az};
        }
    }
}

// 4. First half of kick and drift

__global__ void kick_and_drift(
    DeviceState bodies,
    const Vector* acceleration,
    unsigned int count
) {
    const unsigned int i =
        blockIdx.x * blockDim.x + threadIdx.x;

    if (i >= count) {
        return;
    }
    const double dt = physics_const.dt;
    const double half_dt = 0.5 * dt;

    // First half-kick.
    bodies.vx[i] += half_dt * acceleration[i].x;
    bodies.vy[i] += half_dt * acceleration[i].y;
    bodies.vz[i] += half_dt * acceleration[i].z;

    // Drift.
    bodies.x[i] += dt * bodies.vx[i];
    bodies.y[i] += dt * bodies.vy[i];
    bodies.z[i] += dt * bodies.vz[i];
}

// 5. Second half of kick

__global__ void finish_kick(
    DeviceState bodies,
    const Vector* acceleration,
    unsigned int count
) {
    const unsigned int i =
        blockIdx.x * blockDim.x + threadIdx.x;

    if (i >= count) {
        return;
    }

    const double half_dt = 0.5 * physics_const.dt;

    bodies.vx[i] += half_dt * acceleration[i].x;
    bodies.vy[i] += half_dt * acceleration[i].y;
    bodies.vz[i] += half_dt * acceleration[i].z;
}

// 6. CUDA event wrapper

class Event {
public:
    Event() {
        check_cuda(
            cudaEventCreate(&event_),
            "Create CUDA event"
        );
    }

    ~Event() {
        cudaEventDestroy(event_);
    }

    Event(const Event&) = delete;
    Event& operator=(const Event&) = delete;

    void record() const {
        check_cuda(
            cudaEventRecord(event_),
            "Record CUDA event"
        );
    }

    void wait() const {
        check_cuda(
            cudaEventSynchronize(event_),
            "Wait for CUDA event"
        );
    }

    double seconds_since(const Event& start) const {
        float milliseconds = 0.0f;

        check_cuda(
            cudaEventElapsedTime(
                &milliseconds,
                start.event_,
                event_
            ),
            "Read CUDA event time"
        );

        return milliseconds / 1000.0;
    }

private:
    cudaEvent_t event_ = nullptr;
};

// 7. GPU simulation

class GpuSimulation {

public:

    GpuSimulation(
        unsigned int count,
        nbody::Parameters physics,
        KernelConfig config
    )
        : count_(count),
          config_(config),
          physics_(physics),

          x_(device_buffer<double>(count)),
          y_(device_buffer<double>(count)),
          z_(device_buffer<double>(count)),

          vx_(device_buffer<double>(count)),
          vy_(device_buffer<double>(count)),
          vz_(device_buffer<double>(count)),

          mass_(device_buffer<double>(count)),

          acceleration_(device_buffer<Vector>(count))
    {
        if (count_ == 0) {
            throw std::invalid_argument(
                "The number of bodies must be positive."
            );
        }

        if (config_.tile_size == 0 ||
            config_.block_size == 0) {
            throw std::invalid_argument(
                "Tile size and block size must be positive."
            );
        }

        // Automatically calculate grid size if not specified.
        const unsigned int minimum_grid =
            (count_ + config_.block_size - 1)
            / config_.block_size;

        if (config_.grid_size == 0) {
            config_.grid_size = minimum_grid;
        }

        if (config_.grid_size < minimum_grid) {
            throw std::invalid_argument(
                "Grid size is too small to process all bodies."
            );
        }

        // Validate block size against GPU limits.
        int device = 0;
        int max_threads = 0;
        int max_shared_memory = 0;

        check_cuda(cudaGetDevice(&device), "Get CUDA device");

        check_cuda(
            cudaDeviceGetAttribute(
                &max_threads,
                cudaDevAttrMaxThreadsPerBlock,
                device
            ),
            "Get maximum threads per block"
        );

        check_cuda(
            cudaDeviceGetAttribute(
                &max_shared_memory,
                cudaDevAttrMaxSharedMemoryPerBlock,
                device
            ),
            "Get maximum shared memory"
        );

        if (config_.block_size > static_cast<unsigned int>(max_threads)) {
            throw std::invalid_argument(
                "Block size exceeds the GPU limit."
            );
        }

        const std::size_t shared_bytes =
            4ULL * config_.tile_size * sizeof(double);

        if (shared_bytes > max_shared_memory) {
            throw std::invalid_argument(
                "Tile size requires too much shared memory."
            );
        }
    }

    // Upload initial state: CPU SoA -> GPU SoA

    void upload(const nbody::State& state) {

        state.validate();

        if (state.size() != count_) {
            throw std::invalid_argument(
                "State size does not match GPU simulation size."
            );
        }

        const std::size_t bytes =
            count_ * sizeof(double);

        check_cuda(
            cudaMemcpy(x_.get(), state.x.data(), bytes,
                       cudaMemcpyHostToDevice),
            "Upload x"
        );

        check_cuda(
            cudaMemcpy(y_.get(), state.y.data(), bytes,
                       cudaMemcpyHostToDevice),
            "Upload y"
        );

        check_cuda(
            cudaMemcpy(z_.get(), state.z.data(), bytes,
                       cudaMemcpyHostToDevice),
            "Upload z"
        );

        check_cuda(
            cudaMemcpy(vx_.get(), state.vx.data(), bytes,
                       cudaMemcpyHostToDevice),
            "Upload vx"
        );

        check_cuda(
            cudaMemcpy(vy_.get(), state.vy.data(), bytes,
                       cudaMemcpyHostToDevice),
            "Upload vy"
        );

        check_cuda(
            cudaMemcpy(vz_.get(), state.vz.data(), bytes,
                       cudaMemcpyHostToDevice),
            "Upload vz"
        );

        check_cuda(
            cudaMemcpy(mass_.get(), state.mass.data(), bytes,
                       cudaMemcpyHostToDevice),
            "Upload mass"
        );
    }

    void upload_physics() {
        DevicePhysics physics_data{
            physics_.gravitational_constant,
            physics_.softening * physics_.softening,
            physics_.dt
        };

        check_cuda(
            cudaMemcpyToSymbol(
                physics_const,
                &physics_data,
                sizeof(DevicePhysics)
            ),
            "Copy physics parameters to constant memory"
        );
    }

    // Initialize acceleration

    void initialize_acceleration() {
        update_acceleration();
    }

    // Advance simulation

    void advance(std::uint64_t steps) {

        for (std::uint64_t step = 0; step < steps; ++step) {

            // First half-kick + drift.
            kick_and_drift<<<
                config_.grid_size,
                config_.block_size
            >>>(
                device_state(),
                acceleration_.get(),
                count_
            );

            check_cuda(
                cudaGetLastError(),
                "Launch kick and drift"
            );

            // Recalculate acceleration at new positions.
            update_acceleration();

            // Second half-kick.
            finish_kick<<<
                config_.grid_size,
                config_.block_size
            >>>(
                device_state(),
                acceleration_.get(),
                count_
            );

            check_cuda(
                cudaGetLastError(),
                "Launch finish kick"
            );
        }
    }

    // Download GPU -> CPU

    void download(nbody::State& state) const {

        const std::size_t bytes =
            count_ * sizeof(double);

        check_cuda(
            cudaMemcpy(state.x.data(), x_.get(), bytes,
                       cudaMemcpyDeviceToHost),
            "Download x"
        );

        check_cuda(
            cudaMemcpy(state.y.data(), y_.get(), bytes,
                       cudaMemcpyDeviceToHost),
            "Download y"
        );

        check_cuda(
            cudaMemcpy(state.z.data(), z_.get(), bytes,
                       cudaMemcpyDeviceToHost),
            "Download z"
        );

        check_cuda(
            cudaMemcpy(state.vx.data(), vx_.get(), bytes,
                       cudaMemcpyDeviceToHost),
            "Download vx"
        );

        check_cuda(
            cudaMemcpy(state.vy.data(), vy_.get(), bytes,
                       cudaMemcpyDeviceToHost),
            "Download vy"
        );

        check_cuda(
            cudaMemcpy(state.vz.data(), vz_.get(), bytes,
                       cudaMemcpyDeviceToHost),
            "Download vz"
        );

        check_cuda(
            cudaMemcpy(state.mass.data(), mass_.get(), bytes,
                       cudaMemcpyDeviceToHost),
            "Download mass"
        );
    }

    unsigned int grid_size() const noexcept {
        return config_.grid_size;
    }

private:

   // Return GPU SoA structure

    DeviceState device_state() const {
        return {
            x_.get(),
            y_.get(),
            z_.get(),
            vx_.get(),
            vy_.get(),
            vz_.get(),
            mass_.get()
        };
    }

    // Update acceleration using 1D tiling

    void update_acceleration() {

        const std::size_t shared_bytes =
            4ULL * config_.tile_size * sizeof(double);

        calculate_acceleration_tiled<<<
            config_.grid_size,
            config_.block_size,
            shared_bytes
        >>>(
            device_state(),
            acceleration_.get(),
            count_,
            config_.tile_size
        );

        check_cuda(
            cudaGetLastError(),
            "Launch acceleration calculation"
        );
    }

    // Members

    unsigned int count_;

    KernelConfig config_;

    nbody::Parameters physics_;

    std::unique_ptr<double, decltype(&cudaFree)> x_{
        device_buffer<double>(0)
    };

    std::unique_ptr<double, decltype(&cudaFree)> y_{
        device_buffer<double>(0)
    };

    std::unique_ptr<double, decltype(&cudaFree)> z_{
        device_buffer<double>(0)
    };

    std::unique_ptr<double, decltype(&cudaFree)> vx_{
        device_buffer<double>(0)
    };

    std::unique_ptr<double, decltype(&cudaFree)> vy_{
        device_buffer<double>(0)
    };

    std::unique_ptr<double, decltype(&cudaFree)> vz_{
        device_buffer<double>(0)
    };

    std::unique_ptr<double, decltype(&cudaFree)> mass_{
        device_buffer<double>(0)
    };

    std::unique_ptr<Vector, decltype(&cudaFree)> acceleration_{
        device_buffer<Vector>(0)
    };
};

} // namespace


int main(int argc, char** argv) {
    using namespace nbody;
    try {
        const auto options = parse_options(argc, argv, true);
        KernelConfig config;
        config.block_size = options.block_size;

        const auto initial = make_initial_conditions(options.initial, options.physics);
        EnergyReport report(diagnostics(initial.state, options.physics).total_energy());

        GpuSimulation simulation(static_cast<unsigned int>(initial.state.size()), options.physics, config);
        State checkpoint(initial.state.size());
        Timings timings;
        Event gpu_start, compute_start, compute_end;
        gpu_start.record();
        simulation.upload(initial.state);
        simulation.upload_physics();
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
            simulation.download(checkpoint);
            check_cuda(cudaStreamSynchronize(nullptr), "Wait for the energy checkpoint");
            report.observe(diagnostics(checkpoint, options.physics).total_energy());
            step += batch;
        }
        return print_benchmark("gpu-optim", options, timings, report);
    } catch (const std::exception& error) {
        std::cerr << "nbody_gpu_optim: " << error.what() << '\n';
        return 1;
    }
}
