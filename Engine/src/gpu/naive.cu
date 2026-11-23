// Run the direct N-body calculation on CUDA, with one thread per body.
#include <cuda_runtime.h>
#include "nbody/benchmark.hpp"
#include <cmath>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>

namespace {
struct Vector { double x, y, z; };
struct Body {
    Vector position, velocity;
    double mass;
};

__global__ void calculate_acceleration(const Body* bodies, Vector* acceleration,
                                       unsigned int count, double gravity, double softening_squared) {
    const auto i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= count) return;

    const Vector position = bodies[i].position;
    Vector sum{};
    for (unsigned int j = 0; j < count; ++j) {
        if (j == i) continue;

        const double dx = bodies[j].position.x - position.x;
        const double dy = bodies[j].position.y - position.y;
        const double dz = bodies[j].position.z - position.z;
        const double r2 = dx * dx + dy * dy + dz * dz + softening_squared;
        if (!(r2 > 0.0) || !isfinite(r2)) {
            // The energy check on the host will report the invalid state.
            const double invalid = nan("");
            acceleration[i] = {invalid, invalid, invalid};
            return;
        }
        const double inverse_r = 1.0 / sqrt(r2);
        const double factor = gravity * bodies[j].mass * (inverse_r * inverse_r * inverse_r);
        sum.x += factor * dx;
        sum.y += factor * dy;
        sum.z += factor * dz;
    }
    acceleration[i] = sum;
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
    GpuSimulation(unsigned int count, unsigned int block_size, nbody::Parameters physics)
        : count_(count), block_size_(block_size), grid_size_((count + block_size - 1) / block_size),
          physics_(physics), bodies_(device_buffer<Body>(count)),
          acceleration_(device_buffer<Vector>(count)), host_(host_buffer(count)) {}

    ~GpuSimulation() { cudaStreamSynchronize(nullptr); }

    unsigned int grid_size() const { return grid_size_; }

    void prepare(const nbody::State& state) {
        for (unsigned int i = 0; i < count_; ++i) {
            host_[i] = {{state.x[i], state.y[i], state.z[i]},
                        {state.vx[i], state.vy[i], state.vz[i]}, state.mass[i]};
        }
    }

    void upload() {
        check_cuda(cudaMemcpyAsync(bodies_.get(), host_.get(), sizeof(Body) * count_, cudaMemcpyHostToDevice),
                   "Copy the initial state to the GPU");
        update_acceleration();
    }

    void advance(std::uint64_t steps) {
        for (std::uint64_t step = 0; step < steps; ++step) {
            kick_and_drift<<<grid_size_, block_size_>>>(bodies_.get(), acceleration_.get(), count_, physics_.dt);
            check_cuda(cudaGetLastError(), "Launch kick and drift");
            update_acceleration();
            finish_kick<<<grid_size_, block_size_>>>(bodies_.get(), acceleration_.get(), count_, 0.5 * physics_.dt);
            check_cuda(cudaGetLastError(), "Launch final kick");
        }
    }

    void download() {
        check_cuda(cudaMemcpyAsync(host_.get(), bodies_.get(), sizeof(Body) * count_, cudaMemcpyDeviceToHost),
                   "Copy the state back to the host");
    }

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
    void update_acceleration() {
        calculate_acceleration<<<grid_size_, block_size_>>>(
            bodies_.get(), acceleration_.get(), count_, physics_.gravitational_constant,
            physics_.softening * physics_.softening);
        check_cuda(cudaGetLastError(), "Launch acceleration calculation");
    }

    unsigned int count_, block_size_, grid_size_;
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
        const auto start = Clock::now();
        int device = 0;
        int max_threads = 0;
        check_cuda(cudaGetDevice(&device), "Select a CUDA device");
        check_cuda(cudaDeviceGetAttribute(&max_threads, cudaDevAttrMaxThreadsPerBlock, device),
                   "Read the device block size limit");
        if (options.block_size > static_cast<unsigned int>(max_threads))
            throw std::invalid_argument("Block size exceeds the limit of this GPU.");

        const auto initial = make_initial_conditions(options.initial, options.physics);
        const auto check_start = Clock::now();
        EnergyReport report(diagnostics(initial.state, options.physics).total_energy());
        Timings timings;
        timings.validation = seconds(Clock::now() - check_start);

        GpuSimulation simulation(static_cast<unsigned int>(initial.state.size()), options.block_size, options.physics);
        simulation.prepare(initial.state);
        Event gpu_start, gpu_end, compute_start, compute_end;
        gpu_start.record();
        simulation.upload();
        compute_start.record();
        simulation.advance(options.steps);
        compute_end.record();
        simulation.download();
        gpu_end.record();
        gpu_end.wait();

        timings.compute = compute_end.seconds_since(compute_start);
        timings.gpu_total = gpu_end.seconds_since(gpu_start);
        timings.grid_size = simulation.grid_size();

        const auto final_check_start = Clock::now();
        State checkpoint(initial.state.size());
        const double final_energy = simulation.energy(checkpoint);
        // Replay only up to the last intermediate check, outside the CUDA timers.
        const auto interval = options.energy_every;
        if (interval != 0 && interval < options.steps) {
            simulation.prepare(initial.state);
            simulation.upload();
            for (std::uint64_t step = 0; interval < options.steps - step; step += interval) {
                simulation.advance(interval);
                simulation.download();
                check_cuda(cudaStreamSynchronize(nullptr), "Wait for the energy checkpoint");
                report.observe(simulation.energy(checkpoint));
            }
        }
        report.observe(final_energy);
        timings.validation += seconds(Clock::now() - final_check_start);
        timings.total = seconds(Clock::now() - start);
        return print_benchmark("gpu-naive", options, timings, report);
    } catch (const std::exception& error) {
        std::cerr << "nbody_gpu_naive: " << error.what() << '\n';
        return 1;
    }
}
