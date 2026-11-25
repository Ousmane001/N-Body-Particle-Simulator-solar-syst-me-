// Benchmark options, timings, and energy checks.
#pragma once
#include "initial_conditions.hpp"
#include <chrono>
#include <optional>

namespace nbody {
using Clock = std::chrono::steady_clock;
inline double seconds(Clock::duration duration) {
    return std::chrono::duration<double>(duration).count();
}

struct Options {
    InitialOptions initial;
    Parameters physics;
    std::uint64_t steps = 0;
    std::uint64_t energy_every = 0;
    std::optional<double> max_energy_drift;
    unsigned int block_size = 0;
    std::size_t threads = 1;
    bool json = false;
};

struct Timings {
    // CPU runs use the same value for both fields. On CUDA, the second time includes transfers.
    double compute = 0.0;
    double with_transfer = 0.0;
};

struct EnergyReport {
    explicit EnergyReport(double initial_energy);
    void observe(double value);

    double initial;
    // The final signed change goes in the JSON. The largest change is used for validation.
    double delta = 0.0;
    double max_absolute_drift = 0.0;
};

Options parse_options(int argc, char** argv, bool gpu = false, bool parallel_cpu = false);
void record_gpu_force_timings(double compute, double with_transfer);
std::optional<Timings> take_gpu_force_timings();
int print_benchmark(const char* algo, const Options& options, std::optional<Timings> timings,
                    const EnergyReport& energy);
} // namespace nbody
