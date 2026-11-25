// Version CUDA optimisee en Structure of Arrays (SoA) avec tuilage en shared memory.
// Objectif : profiter du coalescing memoire lors du chargement des tuiles SoA
// tout en evitant les atomicAdd (1 thread par corps cible, accumulation en registres).
#include "benchmark.hpp"
#include "gpu.hpp"
#include <cuda_runtime.h>
#include <cmath>
#include <cstddef>
#include <stdexcept>
#include <string>

namespace {

constexpr int invalid_distance = 1;
constexpr int acceleration_overflow = 2;

void check_cuda(cudaError_t status, const char* operation) {
    if (status != cudaSuccess)
        throw std::runtime_error(std::string(operation) + ": " + cudaGetErrorString(status));
}

#define CUDA_CHECK(operation) check_cuda((operation), #operation)

// Kernel N-body SoA avec tuilage 1D en shared memory :
// - Chaque thread calcule l'acceleration d'un seul corps cible i (pas d'atomicAdd).
// - Chaque bloc charge les corps sources par tuiles de taille blockDim.x de maniere
//   coalescente depuis les tableaux SoA vers la shared memory.
__global__ void direct_acceleration_tiled_soa_kernel(
    const double* __restrict__ x,
    const double* __restrict__ y,
    const double* __restrict__ z,
    const double* __restrict__ mass,
    double* __restrict__ ax_out,
    double* __restrict__ ay_out,
    double* __restrict__ az_out,
    int N,
    double G,
    double epsilon_squared,
    int* __restrict__ error
) {
    // Memoire partagee decoupee en 4 tableaux SoA de taille blockDim.x.
    extern __shared__ double shared[];
    double* sh_x    = shared;
    double* sh_y    = sh_x + blockDim.x;
    double* sh_z    = sh_y + blockDim.x;
    double* sh_mass = sh_z + blockDim.x;

    const int tid = static_cast<int>(threadIdx.x);
    const int i = static_cast<int>(blockIdx.x * blockDim.x) + tid;
    const bool active = (i < N);

    // Lecture coalescente de la cible i en registres avant la boucle sur les tuiles.
    const double xi = active ? x[i] : 0.0;
    const double yi = active ? y[i] : 0.0;
    const double zi = active ? z[i] : 0.0;

    double acc_x = 0.0;
    double acc_y = 0.0;
    double acc_z = 0.0;

    // Parcours des sources par blocs (tuiles) pour reutiliser chaque chargement global.
    for (int tile_start = 0; tile_start < N; tile_start += static_cast<int>(blockDim.x)) {
        const int src = tile_start + tid;

        // Tous les threads du warp lisent des adresses adjacentes (acces coalescent).
        if (src < N) {
            sh_x[tid] = x[src];
            sh_y[tid] = y[src];
            sh_z[tid] = z[src];
            sh_mass[tid] = mass[src];
        }
        __syncthreads();

        if (active) {
            const int remaining = N - tile_start;
            const int tile_count = remaining < static_cast<int>(blockDim.x)
                                   ? remaining
                                   : static_cast<int>(blockDim.x);

            #pragma unroll 8
            for (int k = 0; k < tile_count; ++k) {
                if (i == tile_start + k) continue;

                const double dx = sh_x[k] - xi;
                const double dy = sh_y[k] - yi;
                const double dz = sh_z[k] - zi;

                const double r2 = dx * dx + dy * dy + dz * dz + epsilon_squared;
                if (!(r2 > 0.0) || !isfinite(r2)) {
                    // The thread still needs to reach the barrier at the end of the tile.
                    atomicCAS(error, 0, invalid_distance);
                    continue;
                }
                const double inv_r = rsqrt(r2);
                const double factor = G * sh_mass[k] * (inv_r * inv_r * inv_r);

                acc_x += factor * dx;
                acc_y += factor * dy;
                acc_z += factor * dz;
            }
        }
        __syncthreads();
    }

    if (active) {
        if (!isfinite(acc_x) || !isfinite(acc_y) || !isfinite(acc_z)) {
            atomicCAS(error, 0, acceleration_overflow);
            return;
        }
        // Ecriture coalescente des resultats en memoire globale.
        ax_out[i] = acc_x;
        ay_out[i] = acc_y;
        az_out[i] = acc_z;
    }
}

// Reutilisation des buffers GPU entre les appels pour eviter des cudaMalloc/cudaFree
// a chaque pas de temps (comme dans naive.cu).
struct GpuWorkspace {
    double* d_x = nullptr;
    double* d_y = nullptr;
    double* d_z = nullptr;
    double* d_mass = nullptr;
    double* d_ax = nullptr;
    double* d_ay = nullptr;
    double* d_az = nullptr;
    int* d_error = nullptr;
    int capacity = 0;

    cudaEvent_t start = nullptr;
    cudaEvent_t stop = nullptr;
    cudaEvent_t kernel_start = nullptr;
    cudaEvent_t kernel_stop = nullptr;

    void release_buffers() noexcept {
        if (d_x) cudaFree(d_x);
        if (d_y) cudaFree(d_y);
        if (d_z) cudaFree(d_z);
        if (d_mass) cudaFree(d_mass);
        if (d_ax) cudaFree(d_ax);
        if (d_ay) cudaFree(d_ay);
        if (d_az) cudaFree(d_az);
        if (d_error) cudaFree(d_error);
        d_x = d_y = d_z = d_mass = d_ax = d_ay = d_az = nullptr;
        d_error = nullptr;
        capacity = 0;
    }

    ~GpuWorkspace() {
        release_buffers();
        if (start) cudaEventDestroy(start);
        if (stop) cudaEventDestroy(stop);
        if (kernel_start) cudaEventDestroy(kernel_start);
        if (kernel_stop) cudaEventDestroy(kernel_stop);
    }

    void ensure_ready(int N) {
        if (!start) CUDA_CHECK(cudaEventCreate(&start));
        if (!stop) CUDA_CHECK(cudaEventCreate(&stop));
        if (!kernel_start) CUDA_CHECK(cudaEventCreate(&kernel_start));
        if (!kernel_stop) CUDA_CHECK(cudaEventCreate(&kernel_stop));
        if (N <= capacity) return;

        release_buffers();
        const std::size_t bytes = sizeof(double) * static_cast<std::size_t>(N);
        CUDA_CHECK(cudaMalloc(&d_x, bytes));
        CUDA_CHECK(cudaMalloc(&d_y, bytes));
        CUDA_CHECK(cudaMalloc(&d_z, bytes));
        CUDA_CHECK(cudaMalloc(&d_mass, bytes));
        CUDA_CHECK(cudaMalloc(&d_ax, bytes));
        CUDA_CHECK(cudaMalloc(&d_ay, bytes));
        CUDA_CHECK(cudaMalloc(&d_az, bytes));
        CUDA_CHECK(cudaMalloc(&d_error, sizeof(int)));
        capacity = N;
    }
};

} // namespace

namespace nbody {

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

    const double epsilon_squared = parameters.softening * parameters.softening;

    const int N = static_cast<int>(state.size());
    const std::size_t bytes = sizeof(double) * static_cast<std::size_t>(N);
    const int num_blocks = (N + threads_per_block - 1) / threads_per_block;
    const std::size_t shared_bytes = 4 * static_cast<std::size_t>(threads_per_block) * sizeof(double);

    acceleration.x.resize(N);
    acceleration.y.resize(N);
    acceleration.z.resize(N);

    static GpuWorkspace ws;
    ws.ensure_ready(N);

    float ms_total = 0.0f;
    float ms_kernel = 0.0f;

    CUDA_CHECK(cudaEventRecord(ws.start));

    CUDA_CHECK(cudaMemcpy(ws.d_x, state.x.data(), bytes, cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(ws.d_y, state.y.data(), bytes, cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(ws.d_z, state.z.data(), bytes, cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemcpy(ws.d_mass, state.mass.data(), bytes, cudaMemcpyHostToDevice));
    CUDA_CHECK(cudaMemset(ws.d_error, 0, sizeof(int)));

    CUDA_CHECK(cudaEventRecord(ws.kernel_start));

    direct_acceleration_tiled_soa_kernel<<<num_blocks, threads_per_block, shared_bytes>>>(
        ws.d_x, ws.d_y, ws.d_z, ws.d_mass,
        ws.d_ax, ws.d_ay, ws.d_az,
        N,
        parameters.gravitational_constant,
        epsilon_squared,
        ws.d_error
    );

    CUDA_CHECK(cudaGetLastError());
    CUDA_CHECK(cudaEventRecord(ws.kernel_stop));
    CUDA_CHECK(cudaEventSynchronize(ws.kernel_stop));
    CUDA_CHECK(cudaEventElapsedTime(&ms_kernel, ws.kernel_start, ws.kernel_stop));

    int error = 0;
    CUDA_CHECK(cudaMemcpy(&error, ws.d_error, sizeof(int), cudaMemcpyDeviceToHost));
    if (error == invalid_distance)
        throw std::domain_error("Invalid pair distance; use positive softening for coincident bodies.");
    if (error == acceleration_overflow)
        throw std::overflow_error("Acceleration overflow.");

    CUDA_CHECK(cudaMemcpy(acceleration.x.data(), ws.d_ax, bytes, cudaMemcpyDeviceToHost));
    CUDA_CHECK(cudaMemcpy(acceleration.y.data(), ws.d_ay, bytes, cudaMemcpyDeviceToHost));
    CUDA_CHECK(cudaMemcpy(acceleration.z.data(), ws.d_az, bytes, cudaMemcpyDeviceToHost));

    CUDA_CHECK(cudaEventRecord(ws.stop));
    CUDA_CHECK(cudaEventSynchronize(ws.stop));
    CUDA_CHECK(cudaEventElapsedTime(&ms_total, ws.start, ws.stop));

    record_gpu_force_timings(ms_kernel / 1000.0, ms_total / 1000.0);
}

} // namespace nbody
