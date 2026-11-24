// Benchmark arguments and the result format shared by CPU and GPU.
#include "benchmark.hpp"
#include <algorithm>
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <locale>
#include <stdexcept>
#include <utility>

namespace nbody {
namespace {
// The force-only GPU runner collects one measurement for each force call.
thread_local std::optional<Timings> force_timings;

std::uint64_t integer(const std::string& text, const std::string& option, bool allow_zero = false) {
    std::uint64_t value = 0;
    const auto result = std::from_chars(text.data(), text.data()+text.size(), value);
    if (result.ec != std::errc{} || result.ptr != text.data()+text.size() || (!allow_zero && value == 0))
        throw std::invalid_argument("Invalid integer for " + option);
    return value;
}
double number(const std::string& text) {
    std::size_t end = 0;
    const double value = std::stod(text, &end);
    if (end != text.size() || !std::isfinite(value)) throw std::invalid_argument("Expected a finite number.");
    return value;
}
} // namespace

Options parse_options(int argc, char** argv, bool gpu) {
    Options options;
    if (gpu) options.block_size = 256;
    bool count_set = false;
    bool energy_every_set = false;
    for (int i = 1; i < argc; ++i) {
        const std::string name = argv[i];
        if (name == "--help") {
            std::cout << (gpu ? "CUDA N-body benchmark\n" : "Sequential CPU N-body simulation (C++17)\n")
                      << "  --scenario solar|binary|cluster|galaxy|merger\n"
                      << "  --count N       default: solar 9, binary 2, others 1000\n"
                      << "  --galaxies N    2 to 4, for merger\n"
                      << "  --dt X          fixed time step, default 0.001\n"
                      << "  --steps N       optional finite run with compute timing\n"
                      << "  --energy-every K   check every K steps, in addition to start and end (default 0)\n"
                      << "  --max-energy-drift X   optional relative limit, e.g. 0.001 for 0.1%\n"
                      << "  --json          print the finite run summary as JSON\n";
            if (gpu) std::cout << "  --block-size N  threads per block, default 256; --steps is required.\n";
            else std::cout << "Without --steps: read 'step N' or 'quit' from stdin.\n";
            std::exit(0);
        }
        if (name == "--json") {
            options.json = true;
            continue;
        }
        if (++i == argc) throw std::invalid_argument("Missing value for " + name);
        const std::string value = argv[i];
        if (name == "--scenario") options.initial.scenario = value;
        else if (name == "--count") {
            const auto count = integer(value, name);
            if (count > 1000000) throw std::invalid_argument("Count exceeds 1000000.");
            options.initial.count = static_cast<std::size_t>(count); count_set = true;
        } else if (name == "--galaxies") {
            const auto count = integer(value, name);
            if (count < 2 || count > 4) throw std::invalid_argument("Choose 2 to 4 galaxies.");
            options.initial.galaxies = static_cast<std::size_t>(count);
        } else if (name == "--steps") options.steps = integer(value, name);
        else if (name == "--energy-every") {
            options.energy_every = integer(value, name, true);
            energy_every_set = true;
        } else if (name == "--max-energy-drift") {
            options.max_energy_drift = number(value);
            if (*options.max_energy_drift < 0.0)
                throw std::invalid_argument("--max-energy-drift must be nonnegative.");
        } else if (name == "--block-size" && gpu) {
            const auto threads = integer(value, name);
            if (threads > 1024) throw std::invalid_argument("Block size exceeds 1024.");
            options.block_size = static_cast<unsigned int>(threads);
        } else if (name == "--dt") options.physics.dt = number(value);
        else throw std::invalid_argument("Unknown option: " + name);
    }
    // The solar and binary scenarios have fixed sizes. Cluster benchmarks default to 1000 bodies.
    if (!count_set) options.initial.count = options.initial.scenario == "solar" ? 9 : options.initial.scenario == "binary" ? 2 : 1000;
    if (gpu && options.steps == 0) throw std::invalid_argument("The CUDA benchmark requires --steps.");
    if (options.steps == 0 && (energy_every_set || options.max_energy_drift || options.json))
        throw std::invalid_argument("--energy-every, --max-energy-drift and --json require --steps.");
    options.physics.validate();
    if (!std::isfinite(static_cast<double>(options.steps)*options.physics.dt)) throw std::invalid_argument("Duration overflow.");
    return options;
}

void record_gpu_force_timings(double compute, double with_transfer) {
    if (!force_timings) force_timings.emplace();
    force_timings->compute += compute;
    force_timings->with_transfer += with_transfer;
}

std::optional<Timings> take_gpu_force_timings() {
    return std::exchange(force_timings, std::nullopt);
}

EnergyReport::EnergyReport(double initial_energy) : initial(initial_energy) {}

void EnergyReport::observe(double value) {
    delta = value - initial;
    if (!std::isfinite(delta)) throw std::overflow_error("Energy drift overflow.");
    max_absolute_drift = std::max(max_absolute_drift, std::abs(delta));
}

int print_benchmark(const char* algo, const Options& options, std::optional<Timings> timings,
                    const EnergyReport& energy) {
    // The worst checkpoint decides whether the run passes, even if the final drift is small.
    const double max_drift = energy.max_absolute_drift == 0.0 ? 0.0 :
        energy.max_absolute_drift / std::abs(energy.initial);
    const bool failed = options.max_energy_drift && max_drift > *options.max_energy_drift;

    std::cout.imbue(std::locale::classic());
    std::cout << std::defaultfloat << std::setprecision(17);
    if (options.json) {
        std::cout << "{\n"
                  << "  \"algo\": \"" << algo << "\",\n"
                  << "  \"nbodies\": " << options.initial.count << ",\n"
                  << "  \"steps\": " << options.steps << ",\n";
        if (timings) {
            std::cout << "  \"compute_seconds\": " << timings->compute << ",\n"
                      << "  \"compute_with_transfer_seconds\": " << timings->with_transfer << ",\n";
        } else {
            std::cout << "  \"compute_seconds\": null,\n"
                      << "  \"compute_with_transfer_seconds\": null,\n";
        }
        std::cout << "  \"simulated_time_per_step\": " << options.physics.dt << ",\n"
                  << "  \"energy_delta\": " << energy.delta << "\n}\n";
    } else {
        std::cout << "algo=" << algo << "\nnbodies=" << options.initial.count
                  << "\nsteps=" << options.steps << '\n';
        if (timings) {
            std::cout << "compute_seconds=" << timings->compute
                      << "\ncompute_with_transfer_seconds=" << timings->with_transfer << '\n';
        }
        std::cout << "scenario=" << options.initial.scenario
                  << "\nsimulated_time_per_step=" << options.physics.dt
                  << "\nenergy_delta=" << energy.delta << '\n';
    }
    if (failed)
        std::cerr << "Maximum relative energy drift " << max_drift
                  << " exceeds limit " << *options.max_energy_drift << ".\n";
    return failed ? 2 : 0;
}
} // namespace nbody
