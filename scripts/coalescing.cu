// CUDA benchmark for reading one field from SoA and AoS layouts.
#include <cuda_runtime.h>
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>

namespace {
constexpr unsigned int block_size = 256;
constexpr std::size_t body_fields = 7;
constexpr std::size_t sample_count = 6;
constexpr double mib = 1024.0 * 1024.0;

void check_cuda(cudaError_t status, const char* operation) {
    if (status != cudaSuccess)
        throw std::runtime_error(std::string(operation) + ": " + cudaGetErrorString(status));
}

auto device_array(std::size_t count) {
    double* data = nullptr;
    check_cuda(cudaMalloc(&data, count * sizeof(double)), "Allocate GPU array");
    return std::unique_ptr<double, decltype(&cudaFree)>(data, cudaFree);
}

unsigned int blocks(std::size_t count) {
    return static_cast<unsigned int>((count + block_size - 1) / block_size);
}

__global__ void fill(double* data, std::size_t count, std::size_t stride) {
    const std::size_t i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < count) {
        // Both layouts get the same x values, and the other fields vary too.
        const auto body = static_cast<std::uint32_t>(i / stride);
        const auto field = static_cast<std::uint32_t>(i % stride);
        const auto bits = body * 2654435761u + field * 2246822519u;
        data[i] = static_cast<double>(bits ^ (bits >> 16));
    }
}

__global__ void read_x(const double* input, double* output, std::size_t count, std::size_t stride) {
    const std::size_t i = blockIdx.x * blockDim.x + threadIdx.x;
    // We read one x per thread. AoS skips the other six fields of each body.
    if (i < count) output[i] = input[i * stride];
}

class Event {
public:
    Event() { check_cuda(cudaEventCreate(&event), "Create timing event"); }
    ~Event() { cudaEventDestroy(event); }
    Event(const Event&) = delete;
    Event& operator=(const Event&) = delete;
    cudaEvent_t event = nullptr;
};

float measure(const double* input, double* output, std::size_t count, std::size_t stride,
              const Event& start, const Event& end) {
    check_cuda(cudaEventRecord(start.event), "Start timing");
    read_x<<<blocks(count), block_size>>>(input, output, count, stride);
    check_cuda(cudaGetLastError(), "Launch read kernel");
    check_cuda(cudaEventRecord(end.event), "End timing");
    check_cuda(cudaEventSynchronize(end.event), "Wait for read kernel");
    float ms = 0.0f;
    check_cuda(cudaEventElapsedTime(&ms, start.event, end.event), "Read elapsed time");
    return ms;
}

void report(const char* layout, std::array<float, sample_count> samples, std::size_t bytes) {
    std::sort(samples.begin(), samples.end());
    const double median_ms = (samples[sample_count / 2 - 1] + samples[sample_count / 2]) / 2.0;
    // Useful bytes count one double read and one written per body for both layouts.
    const double gb_per_second = 2.0 * bytes / (median_ms * 1e6);
    std::cout << layout << "  " << median_ms << " ms  " << gb_per_second << " useful GB/s\n";
}
} // namespace

int main() {
    try {
        int device = 0;
        int l2_bytes = 0;
        check_cuda(cudaGetDevice(&device), "Get CUDA device");
        check_cuda(cudaDeviceGetAttribute(&l2_bytes, cudaDevAttrL2CacheSize, device), "Read L2 size");
        if (l2_bytes <= 0) throw std::runtime_error("Could not determine the L2 cache size.");

        // The x array alone is twice the L2 capacity, even in SoA.
        const std::size_t count = 2 * static_cast<std::size_t>(l2_bytes) / sizeof(double);
        const std::size_t bytes = count * sizeof(double);
        std::size_t free_bytes = 0, total_bytes = 0;
        check_cuda(cudaMemGetInfo(&free_bytes, &total_bytes), "Read free GPU memory");
        if ((body_fields + 2) * bytes > free_bytes)
            throw std::runtime_error("Not enough free GPU memory for both arrays and the output.");

        const auto soa = device_array(count);
        const auto aos = device_array(count * body_fields);
        const auto output = device_array(count);
        fill<<<blocks(count), block_size>>>(soa.get(), count, 1);
        fill<<<blocks(count * body_fields), block_size>>>(aos.get(), count * body_fields, body_fields);
        check_cuda(cudaGetLastError(), "Initialize GPU arrays");
        check_cuda(cudaDeviceSynchronize(), "Wait for initialization");

        Event start, end;
        measure(soa.get(), output.get(), count, 1, start, end);
        measure(aos.get(), output.get(), count, body_fields, start, end);
        std::array<float, sample_count> soa_times, aos_times;
        for (std::size_t i = 0; i < sample_count; ++i) {
            // We alternate the order so both layouts run first equally often.
            if (i % 2 == 0) {
                soa_times[i] = measure(soa.get(), output.get(), count, 1, start, end);
                aos_times[i] = measure(aos.get(), output.get(), count, body_fields, start, end);
            } else {
                aos_times[i] = measure(aos.get(), output.get(), count, body_fields, start, end);
                soa_times[i] = measure(soa.get(), output.get(), count, 1, start, end);
            }
        }
        std::cout << std::fixed << std::setprecision(3)
                  << "L2: " << l2_bytes / mib << " MiB, bodies: " << count
                  << ", SoA input: " << bytes / mib << " MiB, AoS input: "
                  << body_fields * bytes / mib << " MiB\n"
                  << "Median of " << sample_count << " reads per layout\n";
        report("SoA", soa_times, bytes);
        report("AoS", aos_times, bytes);
    } catch (const std::exception& error) {
        std::cerr << "coalescing: " << error.what() << '\n';
        return 1;
    }
}
