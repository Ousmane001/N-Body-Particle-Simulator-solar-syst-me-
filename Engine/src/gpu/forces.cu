#include "nbody/gpu.hpp"
#include <cuda_runtime.h>
#include <cmath>
#include <iostream>
#include <iomanip>
#include <stdexcept>
#include <string>

namespace {
void check_cuda(cudaError_t status, const char* operation) {
    if (status != cudaSuccess)
        throw std::runtime_error(std::string(operation) + ": " + cudaGetErrorString(status));
}
}

#define CUDA_CHECK(operation) check_cuda((operation), #operation)

#define NO_ERROR 0
#define INVALID_DISTANCE 1
#define ACCELERATION_OVERFLOW 2

// The CUDA kernel
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

            // Check distance validity
            if (!(distance_squared > 0.0) || !isfinite(distance_squared)) {
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

        // Check acceleration validity
        if (!isfinite(acc_x) || !isfinite(acc_y) || !isfinite(acc_z)) {
            atomicCAS(error, NO_ERROR, ACCELERATION_OVERFLOW);
            return;
        }

        ax[i] = acc_x;
        ay[i] = acc_y;
        az[i] = acc_z;
    }

    // Host function (executed on CPU)
    void gpu_direct_acceleration(
        const State& state,
        const Parameters& parameters,
        Acceleration& acceleration,
        int threads_per_block
    ) {
        // 1. Validate inputs
        state.validate();
        parameters.validate();

        if (threads_per_block <= 0 || threads_per_block > 1024)
            throw std::invalid_argument("Invalid block size.");

        const int N = static_cast<int>(state.size());
        const size_t bytes = sizeof(double) * N;

        // 2. Calculate execution configuration
        const int num_blocks = (N + threads_per_block - 1) / threads_per_block;

        // 3. Allocate CPU output vectors
        acceleration.x.resize(N);
        acceleration.y.resize(N);
        acceleration.z.resize(N);

        // 4. Allocate GPU memory
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

        // 5. Create CUDA events for total execution time
        cudaEvent_t start, stop;
        CUDA_CHECK(cudaEventCreate(&start));
        CUDA_CHECK(cudaEventCreate(&stop));

        float ms_total = 0.0f;
        CUDA_CHECK(cudaEventRecord(start));

        // 6. Copy input data: CPU -> GPU
        CUDA_CHECK(cudaMemcpy(d_x, state.x.data(), bytes, cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemcpy(d_y, state.y.data(), bytes, cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemcpy(d_z, state.z.data(), bytes, cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaMemcpy(d_mass, state.mass.data(), bytes, cudaMemcpyHostToDevice));

        // 7. Initialize GPU error flag
        CUDA_CHECK(cudaMemset(d_error, NO_ERROR, sizeof(int)));

        // 8. Create CUDA events for kernel execution time
        cudaEvent_t kernel_start, kernel_stop;
        CUDA_CHECK(cudaEventCreate(&kernel_start));
        CUDA_CHECK(cudaEventCreate(&kernel_stop));

        float ms_kernel = 0.0f;

        // Record the beginning of kernel execution
        CUDA_CHECK(cudaEventRecord(kernel_start));

        // 9. Launch CUDA kernel
        direct_acceleration_kernel<<<num_blocks, threads_per_block>>>(
            d_x, d_y, d_z, d_mass,
            d_ax, d_ay, d_az,
            N,
            parameters.gravitational_constant,
            parameters.softening * parameters.softening,
            d_error
        );

        // Check whether the kernel launch was successful
        CUDA_CHECK(cudaGetLastError());

        // Record the end of kernel execution
        CUDA_CHECK(cudaEventRecord(kernel_stop));
        CUDA_CHECK(cudaEventSynchronize(kernel_stop));

        // Calculate kernel execution time
        CUDA_CHECK(cudaEventElapsedTime(
            &ms_kernel, kernel_start, kernel_stop
        ));

        // 10. Retrieve error flag: GPU -> CPU
        int error = NO_ERROR;

        CUDA_CHECK(cudaMemcpy(
            &error, d_error, sizeof(int), cudaMemcpyDeviceToHost
        ));

        if (error == INVALID_DISTANCE)
            throw std::domain_error("Invalid pair distance.");

        if (error == ACCELERATION_OVERFLOW)
            throw std::overflow_error("Acceleration overflow.");

        // 11. Retrieve acceleration results: GPU -> CPU
        CUDA_CHECK(cudaMemcpy(
            acceleration.x.data(), d_ax, bytes, cudaMemcpyDeviceToHost
        ));

        CUDA_CHECK(cudaMemcpy(
            acceleration.y.data(), d_ay, bytes, cudaMemcpyDeviceToHost
        ));

        CUDA_CHECK(cudaMemcpy(
            acceleration.z.data(), d_az, bytes, cudaMemcpyDeviceToHost
        ));

        // 12. Record the end of total execution time
        CUDA_CHECK(cudaEventRecord(stop));
        CUDA_CHECK(cudaEventSynchronize(stop));

        CUDA_CHECK(cudaEventElapsedTime(&ms_total, start, stop));

        // 13. Print performance measurements
        std::cout << std::fixed << std::setprecision(4);
        std::cout << "GPU acceleration results:\n";
        std::cout << "Bodies: " << N << "\n";
        std::cout << "Threads per block: " << threads_per_block << "\n";
        std::cout << "Number of blocks: " << num_blocks << "\n";
        std::cout << "Kernel time: " << ms_kernel << " ms\n";
        std::cout << "Total time (transfers + kernel): " << ms_total << " ms\n";

        // 14. Destroy CUDA events
        CUDA_CHECK(cudaEventDestroy(start));
        CUDA_CHECK(cudaEventDestroy(stop));
        CUDA_CHECK(cudaEventDestroy(kernel_start));
        CUDA_CHECK(cudaEventDestroy(kernel_stop));

        // 15. Free GPU memory
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
