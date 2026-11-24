// Houda's direct gravity calculation with one CUDA thread per body.
#include "benchmark.hpp"
#include "gpu.hpp"
#include <cuda_runtime.h>
#include <cmath>
#include <stdexcept>
#include <string>

namespace {
void check_cuda(cudaError_t status, const char* operation) {
    if (status != cudaSuccess)
        throw std::runtime_error(std::string(operation) + ": " + cudaGetErrorString(status));
}
} // namespace

#define CUDA_CHECK(operation) check_cuda((operation), #operation)

#define NO_ERROR 0
#define INVALID_DISTANCE 1
#define ACCELERATION_OVERFLOW 2

namespace nbody{
    __global__
    void direct_acceleration_kernel(
        const double* x,
        const double* y,
        const double* z,
        const double* mass,

        double* ax,
        double* ay,
        double* az,

        int N,
        double G,
        double epsilon_squared,

        int* error
    ) {
        const int i = blockIdx.x * blockDim.x + threadIdx.x;

        // The last block can have more threads than remaining bodies.
        if (i >= N) return;

        double acc_x = 0.0;
        double acc_y = 0.0;
        double acc_z = 0.0;

        for (int j = 0; j < N; ++j) {

            if (i == j) continue;

            const double dx = x[j] - x[i];
            const double dy = y[j] - y[i];
            const double dz = z[j] - z[i];

            const double distance_squared =
                dx*dx + dy*dy + dz*dz + epsilon_squared;

            if (!(distance_squared > 0.0) || !isfinite(distance_squared)) {
                // The first thread that reports an error keeps its error code.
                atomicCAS(error, NO_ERROR, INVALID_DISTANCE);
                return;
            }

            const double inverse_distance = 1.0 / sqrt(distance_squared);

            const double inverse_distance_cubed =
                inverse_distance * inverse_distance * inverse_distance;

            const double factor =
                G * mass[j] * inverse_distance_cubed;

            acc_x += factor * dx;
            acc_y += factor * dy;
            acc_z += factor * dz;
        }

        if (!isfinite(acc_x) || !isfinite(acc_y) || !isfinite(acc_z)) {
            atomicCAS(error, NO_ERROR, ACCELERATION_OVERFLOW);
            return;
        }

        ax[i] = acc_x;
        ay[i] = acc_y;
        az[i] = acc_z;
    }

    // The CPU sends positions and masses and gets accelerations back on each force call.
    void gpu_direct_acceleration(
        const State& state,
        const Parameters& parameters,
        Acceleration& acceleration,
        int threads_per_block
    ) {
        state.validate();
        parameters.validate();

        if (threads_per_block <= 0 || threads_per_block > 1024)
            throw std::invalid_argument("Invalid block size.");

        const int N = static_cast<int>(state.size());
        const size_t bytes = sizeof(double) * N;

        const int num_blocks = (N + threads_per_block - 1) / threads_per_block;

        acceleration.x.resize(N);
        acceleration.y.resize(N);
        acceleration.z.resize(N);

        double *d_x, *d_y, *d_z, *d_mass;
        double *d_ax, *d_ay, *d_az;
        int* d_error;

        CUDA_CHECK(cudaMalloc(&d_x, bytes));
        CUDA_CHECK(cudaMalloc(&d_y, bytes));
        CUDA_CHECK(cudaMalloc(&d_z, bytes));
        CUDA_CHECK(cudaMalloc(&d_mass, bytes));

        CUDA_CHECK(cudaMalloc(&d_ax, bytes));
        CUDA_CHECK(cudaMalloc(&d_ay, bytes));
        CUDA_CHECK(cudaMalloc(&d_az, bytes));

        CUDA_CHECK(cudaMalloc(&d_error, sizeof(int)));

        // The outer events include transfers in both directions.
        cudaEvent_t start, stop;
        CUDA_CHECK(cudaEventCreate(&start));
        CUDA_CHECK(cudaEventCreate(&stop));

        float ms_total = 0.0f;
        CUDA_CHECK(cudaEventRecord(start));

        CUDA_CHECK(cudaMemcpy(d_x, state.x.data(), bytes, cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemcpy(d_y, state.y.data(), bytes, cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemcpy(d_z, state.z.data(), bytes, cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemcpy(d_mass, state.mass.data(), bytes, cudaMemcpyHostToDevice));

        CUDA_CHECK(cudaMemset(d_error, NO_ERROR, sizeof(int)));

        // The inner events measure the force kernel alone.
        cudaEvent_t kernel_start, kernel_stop;
        CUDA_CHECK(cudaEventCreate(&kernel_start));
        CUDA_CHECK(cudaEventCreate(&kernel_stop));

        float ms_kernel = 0.0f;

        CUDA_CHECK(cudaEventRecord(kernel_start));

        direct_acceleration_kernel<<<num_blocks, threads_per_block>>>(
            d_x, d_y, d_z, d_mass,
            d_ax, d_ay, d_az,
            N,
            parameters.gravitational_constant,
            parameters.softening * parameters.softening,
            d_error
        );

        CUDA_CHECK(cudaGetLastError());

        CUDA_CHECK(cudaEventRecord(kernel_stop));
        CUDA_CHECK(cudaEventSynchronize(kernel_stop));

        CUDA_CHECK(cudaEventElapsedTime(
            &ms_kernel, kernel_start, kernel_stop
        ));

        int error = NO_ERROR;

        CUDA_CHECK(cudaMemcpy(
            &error, d_error, sizeof(int), cudaMemcpyDeviceToHost
        ));

        if (error == INVALID_DISTANCE)
            throw std::domain_error("Invalid pair distance.");

        if (error == ACCELERATION_OVERFLOW)
            throw std::overflow_error("Acceleration overflow.");

        CUDA_CHECK(cudaMemcpy(
            acceleration.x.data(), d_ax, bytes, cudaMemcpyDeviceToHost
        ));

        CUDA_CHECK(cudaMemcpy(
            acceleration.y.data(), d_ay, bytes, cudaMemcpyDeviceToHost
        ));

        CUDA_CHECK(cudaMemcpy(
            acceleration.z.data(), d_az, bytes, cudaMemcpyDeviceToHost
        ));

        CUDA_CHECK(cudaEventRecord(stop));
        CUDA_CHECK(cudaEventSynchronize(stop));

        CUDA_CHECK(cudaEventElapsedTime(&ms_total, start, stop));

        // CUDA events report milliseconds, and the benchmark records seconds.
        record_gpu_force_timings(ms_kernel / 1000.0, ms_total / 1000.0);

        CUDA_CHECK(cudaEventDestroy(start));
        CUDA_CHECK(cudaEventDestroy(stop));
        CUDA_CHECK(cudaEventDestroy(kernel_start));
        CUDA_CHECK(cudaEventDestroy(kernel_stop));

        CUDA_CHECK(cudaFree(d_x));
        CUDA_CHECK(cudaFree(d_y));
        CUDA_CHECK(cudaFree(d_z));
        CUDA_CHECK(cudaFree(d_mass));

        CUDA_CHECK(cudaFree(d_ax));
        CUDA_CHECK(cudaFree(d_ay));
        CUDA_CHECK(cudaFree(d_az));

        CUDA_CHECK(cudaFree(d_error));
    }
}
