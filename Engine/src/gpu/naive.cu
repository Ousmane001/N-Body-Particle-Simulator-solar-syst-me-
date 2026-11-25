// Direct CUDA forces with one object per body and one thread per target.
#include <cuda_runtime.h>
#include "naive_aos.hpp"
#include <cmath>
#include <iostream>
#include <memory>
#include <string>

namespace {
__global__ void force_kernel(const nbody::Body* bodies, nbody::Vec3* accelerations,
                             unsigned int count, double gravity, double epsilon_squared) {
    const auto i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= count) return;

    // Neighboring threads read target coordinates sizeof(Body) bytes apart.
    const auto target = bodies[i].position;
    nbody::Vec3 sum{0.0, 0.0, 0.0};
    for (unsigned int j = 0; j < count; ++j) {
        if (i == j) continue;
        const auto& source = bodies[j];
        const double dx = source.position.x - target.x;
        const double dy = source.position.y - target.y;
        const double dz = source.position.z - target.z;
        const double r2 = dx * dx + dy * dy + dz * dz + epsilon_squared;
        if (!(r2 > 0.0) || !isfinite(r2)) {
            // The CPU energy check will reject the resulting invalid state.
            const double invalid = nan("");
            accelerations[i] = {invalid, invalid, invalid};
            return;
        }
        const double inverse_r = 1.0 / sqrt(r2);
        const double factor = gravity * source.mass * (inverse_r * inverse_r * inverse_r);
        sum.x += factor * dx;
        sum.y += factor * dy;
        sum.z += factor * dz;
    }
    accelerations[i] = sum;
}

void check_cuda(cudaError_t status, const char* operation) {
    if (status != cudaSuccess)
        throw std::runtime_error(std::string(operation) + ": " + cudaGetErrorString(status));
}

template <typename T>
auto device_buffer(std::size_t count) {
    T* buffer = nullptr;
    check_cuda(cudaMalloc(&buffer, count * sizeof(T)), "Allocate GPU memory");
    return std::unique_ptr<T, decltype(&cudaFree)>(buffer, cudaFree);
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
        float milliseconds = 0.0f;
        check_cuda(cudaEventElapsedTime(&milliseconds, start.event_, event_), "Read CUDA event time");
        return milliseconds / 1000.0;
    }

private:
    cudaEvent_t event_ = nullptr;
};

void calculate_forces(const std::vector<nbody::Body>& bodies, const nbody::Parameters& physics,
                      std::vector<nbody::Vec3>& accelerations, unsigned int block_size) {
    const auto count = static_cast<unsigned int>(bodies.size());
    const auto blocks = (count + block_size - 1) / block_size;
    auto gpu_bodies = device_buffer<nbody::Body>(count);
    auto gpu_accelerations = device_buffer<nbody::Vec3>(count);
    Event transfer_start, kernel_start, kernel_end, transfer_end;

    // Each force call sends the whole array of bodies and reads the accelerations back.
    transfer_start.record();
    check_cuda(cudaMemcpy(gpu_bodies.get(), bodies.data(), count * sizeof(nbody::Body),
                          cudaMemcpyHostToDevice), "Copy bodies to GPU");
    kernel_start.record();
    force_kernel<<<blocks, block_size>>>(gpu_bodies.get(), gpu_accelerations.get(), count,
                                        physics.gravitational_constant, physics.softening * physics.softening);
    check_cuda(cudaGetLastError(), "Launch force kernel");
    kernel_end.record();
    check_cuda(cudaMemcpy(accelerations.data(), gpu_accelerations.get(), count * sizeof(nbody::Vec3),
                          cudaMemcpyDeviceToHost), "Copy accelerations to CPU");
    transfer_end.record();
    transfer_end.wait();
    nbody::record_gpu_force_timings(kernel_end.seconds_since(kernel_start),
                                   transfer_end.seconds_since(transfer_start));
}
} // namespace

int main(int argc, char** argv) {
    try {
        const auto options = nbody::parse_options(argc, argv, true);
        auto forces = [block_size = options.block_size](const auto& bodies, const auto& physics, auto& accelerations) {
            calculate_forces(bodies, physics, accelerations, block_size);
        };
        return nbody::run_aos_benchmark("gpu-naive", options, forces);
    } catch (const std::exception& error) {
        std::cerr << "gpu-naive: " << error.what() << '\n';
        return 1;
    }
}
