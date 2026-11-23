// Read simulation options and report timing and energy in the same format for CPU and GPU.
#include "nbody/benchmark.hpp"
#include <algorithm>
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <locale>
#include <stdexcept>

namespace nbody {
namespace {
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
                      << "  --softening X   default 0.02\n"
                      << "  --G X           default 1\n"
                      << "  --seed N        default 42\n"
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
        } else if (name == "--seed") options.initial.seed = integer(value, name, true);
        else if (name == "--dt") options.physics.dt = number(value);
        else if (name == "--softening") options.physics.softening = number(value);
        else if (name == "--G") options.physics.gravitational_constant = number(value);
        else throw std::invalid_argument("Unknown option: " + name);
    }
    if (!count_set) options.initial.count = options.initial.scenario == "solar" ? 9 : options.initial.scenario == "binary" ? 2 : 1000;
    if (gpu && options.steps == 0) throw std::invalid_argument("The CUDA benchmark requires --steps.");
    if (options.steps == 0 && (energy_every_set || options.max_energy_drift || options.json))
        throw std::invalid_argument("--energy-every, --max-energy-drift and --json require --steps.");
    options.physics.validate();
    if (!std::isfinite(static_cast<double>(options.steps)*options.physics.dt)) throw std::invalid_argument("Duration overflow.");
    return options;
}

EnergyReport::EnergyReport(double initial_energy) : initial(initial_energy), final(initial_energy) {}

void EnergyReport::observe(double value) {
    final = value;
    final_absolute_drift = std::abs(final - initial);
    if (!std::isfinite(final_absolute_drift)) throw std::overflow_error("Energy drift overflow.");
    max_absolute_drift = std::max(max_absolute_drift, final_absolute_drift);
    ++checks;
}

int print_benchmark(const char* backend, const Options& options, const Timings& timings, const EnergyReport& energy) {
    const auto relative_drift = [&energy](double drift) -> std::optional<double> {
        if (drift == 0.0) return 0.0;
        if (energy.initial == 0.0) return std::nullopt;
        const double relative = drift / std::abs(energy.initial);
        if (!std::isfinite(relative)) return std::nullopt;
        return relative;
    };
    const auto final_drift = relative_drift(energy.final_absolute_drift);
    const auto max_drift = relative_drift(energy.max_absolute_drift);
    const bool failed = options.max_energy_drift && (!max_drift || *max_drift > *options.max_energy_drift);
    const char* validation_status = failed ? "failed" : options.max_energy_drift ? "passed" : "measured";

    std::cout.imbue(std::locale::classic());
    std::cout << std::setprecision(17);
    if (options.json) {
        const auto write_optional = [](const std::optional<double>& value) {
            if (value) std::cout << *value;
            else std::cout << "null";
        };
        std::cout << "{\n"
                  << "  \"backend\": \"" << backend << "\",\n"
                  << "  \"scenario\": \"" << options.initial.scenario << "\",\n"
                  << "  \"count\": " << options.initial.count << ",\n"
                  << "  \"steps\": " << options.steps << ",\n"
                  << "  \"seed\": " << options.initial.seed << ",\n"
                  << "  \"galaxies\": " << options.initial.galaxies << ",\n"
                  << "  \"dt\": " << options.physics.dt << ",\n"
                  << "  \"softening\": " << options.physics.softening << ",\n"
                  << "  \"G\": " << options.physics.gravitational_constant << ",\n"
                  << "  \"time\": " << options.steps * options.physics.dt << ",\n"
                  << "  \"compute_seconds\": " << timings.compute << ",\n"
                  << "  \"total_seconds\": " << timings.total << ",\n"
                  << "  \"validation_seconds\": " << timings.validation << ",\n"
                  << "  \"gpu_total_seconds\": ";
        write_optional(timings.gpu_total);
        std::cout << ",\n";
        if (options.block_size != 0) {
            std::cout << "  \"grid\": [" << timings.grid_size << ", 1, 1],\n"
                      << "  \"block\": [" << options.block_size << ", 1, 1],\n";
        }
        std::cout << "  \"energy_every\": " << options.energy_every << ",\n"
                  << "  \"energy_checks\": " << energy.checks << ",\n"
                  << "  \"initial_energy\": " << energy.initial << ",\n"
                  << "  \"final_energy\": " << energy.final << ",\n"
                  << "  \"final_absolute_energy_drift\": " << energy.final_absolute_drift << ",\n"
                  << "  \"max_absolute_energy_drift\": " << energy.max_absolute_drift << ",\n"
                  << "  \"final_energy_drift\": ";
        write_optional(final_drift);
        std::cout << ",\n  \"max_energy_drift\": ";
        write_optional(max_drift);
        std::cout << ",\n  \"energy_drift_limit\": ";
        write_optional(options.max_energy_drift);
        std::cout << ",\n  \"validation_status\": \"" << validation_status << "\"\n}\n";
    } else {
        std::cout << "backend=" << backend << "\ncount=" << options.initial.count
                  << "\nsteps=" << options.steps << "\ntime=" << options.steps * options.physics.dt
                  << "\ncompute_seconds=" << timings.compute << "\ninitial_energy=" << energy.initial
                  << "\nfinal_energy=" << energy.final
                  << "\nenergy_checks=" << energy.checks << "\nmax_absolute_energy_drift=" << energy.max_absolute_drift
                  << "\nvalidation_status=" << validation_status << '\n';
        if (timings.gpu_total) {
            std::cout << "gpu_total_seconds=" << *timings.gpu_total
                      << "\ngrid_size=" << timings.grid_size << "\nblock_size=" << options.block_size << '\n';
        }
    }
    return failed ? 2 : 0;
}
} // namespace nbody
