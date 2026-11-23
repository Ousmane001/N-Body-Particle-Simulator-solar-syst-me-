// Share benchmark options, timings, and energy checks between the two executables.
#pragma once
#include "nbody/initial_conditions.hpp"
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
    bool json = false;
};

struct Timings {
    double compute = 0.0;
    double total = 0.0;
    double validation = 0.0;
    std::optional<double> gpu_total;
    unsigned int grid_size = 0;
};

struct EnergyReport {
    explicit EnergyReport(double initial_energy);
    void observe(double value);

    double initial, final;
    double final_absolute_drift = 0.0;
    double max_absolute_drift = 0.0;
    std::uint64_t checks = 1;
};

Options parse_options(int argc, char** argv, bool gpu = false);
int print_benchmark(const char* backend, const Options& options, const Timings& timings, const EnergyReport& energy);
} // namespace nbody
