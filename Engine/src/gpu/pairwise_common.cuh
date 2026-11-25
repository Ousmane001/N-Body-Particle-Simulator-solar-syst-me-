// Shared force formula, GPU buffers and timers for the two pairwise variants.
#pragma once

#include <cuda_runtime.h>
#include "benchmark.hpp"
#include "gpu.hpp"
#include <cmath>
#include <memory>
#include <stdexcept>
#include <string>

namespace {

struct PairVector {
    double x, y, z;
};

struct PairBody {
    PairVector position;
    double mass;
};

struct PairSources {
    const double *x, *y, *z, *mass;

    __device__ PairBody body(unsigned int index) const {
        return {{x[index], y[index], z[index]}, mass[index]};
    }
};

__device__ PairVector pair_direction(PairBody first, PairBody second, double gravity,
                                     double softening_squared) {
    const double dx = second.position.x - first.position.x;
    const double dy = second.position.y - first.position.y;
    const double dz = second.position.z - first.position.z;
    const double r2 = dx * dx + dy * dy + dz * dz + softening_squared;
    if (!(r2 > 0.0) || !isfinite(r2)) {
        const double invalid = nan("");
        return {invalid, invalid, invalid};
    }
    const double inv_r = 1.0 / sqrt(r2);
    const double scale = gravity * (inv_r * inv_r * inv_r);
    return {scale * dx, scale * dy, scale * dz};
}

__device__ void add_component(double* component, double value) {
#if defined(__CUDA_ARCH__) && __CUDA_ARCH__ < 600
    // Older GPUs use compare-and-swap for atomic addition in double precision.
    auto* bits = reinterpret_cast<unsigned long long*>(component);
    auto previous = atomicCAS(bits, 0ULL, 0ULL);
    unsigned long long expected;
    do {
        expected = previous;
        const double sum = __longlong_as_double(expected) + value;
        previous = atomicCAS(bits, expected, __double_as_longlong(sum));
    } while (previous != expected);
#else
    atomicAdd(component, value);
#endif
}

struct PairSums {
    double *x, *y, *z;

    __device__ void add(unsigned int index, PairVector direction, double scale) const {
        add_component(&x[index], scale * direction.x);
        add_component(&y[index], scale * direction.y);
        add_component(&z[index], scale * direction.z);
    }
};

void check_cuda(cudaError_t error, const char* operation) {
    if (error != cudaSuccess)
        throw std::runtime_error(std::string(operation) + ": " + cudaGetErrorString(error));
}

class PairEvent {
public:
    PairEvent() { check_cuda(cudaEventCreate(&event), "Create CUDA timer"); }
    ~PairEvent() { cudaEventDestroy(event); }
    PairEvent(const PairEvent&) = delete;
    PairEvent& operator=(const PairEvent&) = delete;

    void record() const { check_cuda(cudaEventRecord(event), "Record CUDA timer"); }
    void wait() const { check_cuda(cudaEventSynchronize(event), "Wait for CUDA timer"); }
    double seconds_since(const PairEvent& start) const {
        float milliseconds = 0.0f;
        check_cuda(cudaEventElapsedTime(&milliseconds, start.event, event), "Read CUDA timer");
        return milliseconds / 1000.0;
    }

private:
    cudaEvent_t event = nullptr;
};

struct PairWorkspace {
    // Four SoA input arrays and three acceleration arrays fit in one reusable buffer.
    std::unique_ptr<double, decltype(&cudaFree)> buffer{nullptr, cudaFree};
    std::size_t capacity = 0;
    PairEvent start, compute_start, compute_end, end;

    double* storage(std::size_t count) {
        if (count > capacity) {
            double* allocation = nullptr;
            check_cuda(cudaMalloc(&allocation, 7 * count * sizeof(double)), "Allocate pairwise GPU arrays");
            buffer.reset(allocation);
            capacity = count;
        }
        return buffer.get();
    }
};

template <typename Launch>
void run_pairwise(const nbody::State& state, const nbody::Parameters& physics,
                  nbody::Acceleration& result, int threads_per_block, Launch launch) {
    state.validate();
    physics.validate();
    if (threads_per_block <= 0)
        throw std::invalid_argument("Block size must be positive.");

    const std::size_t count = state.size();
    const std::size_t bytes = count * sizeof(double);
    const double softening_squared = physics.softening * physics.softening;
    result.x.resize(count);
    result.y.resize(count);
    result.z.resize(count);

    static thread_local PairWorkspace workspace;
    double* data = workspace.storage(count);
    const PairSources sources{data, data + count, data + 2 * count, data + 3 * count};
    const PairSums sums{data + 4 * count, data + 5 * count, data + 6 * count};

    workspace.start.record();
    check_cuda(cudaMemcpy(data, state.x.data(), bytes, cudaMemcpyHostToDevice), "Upload x");
    check_cuda(cudaMemcpy(data + count, state.y.data(), bytes, cudaMemcpyHostToDevice), "Upload y");
    check_cuda(cudaMemcpy(data + 2 * count, state.z.data(), bytes, cudaMemcpyHostToDevice), "Upload z");
    check_cuda(cudaMemcpy(data + 3 * count, state.mass.data(), bytes, cudaMemcpyHostToDevice), "Upload masses");

    // Atomic sums start at zero every time we calculate new forces.
    workspace.compute_start.record();
    check_cuda(cudaMemset(sums.x, 0, 3 * bytes), "Zero GPU accelerations");
    launch(sources, sums, static_cast<unsigned int>(count), threads_per_block,
           physics.gravitational_constant, softening_squared);
    check_cuda(cudaGetLastError(), "Launch pairwise forces");
    workspace.compute_end.record();

    check_cuda(cudaMemcpy(result.x.data(), sums.x, bytes, cudaMemcpyDeviceToHost), "Download acceleration x");
    check_cuda(cudaMemcpy(result.y.data(), sums.y, bytes, cudaMemcpyDeviceToHost), "Download acceleration y");
    check_cuda(cudaMemcpy(result.z.data(), sums.z, bytes, cudaMemcpyDeviceToHost), "Download acceleration z");
    workspace.end.record();
    workspace.end.wait();
    nbody::record_gpu_force_timings(workspace.compute_end.seconds_since(workspace.compute_start),
                                    workspace.end.seconds_since(workspace.start));

    for (std::size_t i = 0; i < count; ++i) {
        if (!std::isfinite(result.x[i]) || !std::isfinite(result.y[i]) || !std::isfinite(result.z[i]))
            throw std::domain_error("Pairwise acceleration is non-finite (invalid distance or overflow).");
    }
}

} // namespace
