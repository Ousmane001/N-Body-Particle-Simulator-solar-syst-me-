#include "nbody/cpu.hpp"
#include "nbody/initial_conditions.hpp"
#include "nbody/live.hpp"
#include <charconv>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>

namespace {
struct Options {
    nbody::InitialOptions initial;
    nbody::Parameters physics;
    std::uint64_t steps = 0; // Zero selects the interactive live protocol.
};
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
Options parse_options(int argc, char** argv) {
    Options options;
    bool count_set = false;
    for (int i = 1; i < argc; ++i) {
        const std::string name = argv[i];
        if (name == "--help") {
            std::cout << "Sequential CPU N-body simulation (C++17)\n"
                      << "  --scenario solar|binary|cluster|galaxy|merger\n"
                      << "  --count N       default: solar 9, binary 2, others 1000\n"
                      << "  --galaxies N    2 to 4, for merger\n"
                      << "  --dt X          fixed time step, default 0.001\n"
                      << "  --softening X   default 0.02\n"
                      << "  --G X           default 1\n"
                      << "  --seed N        default 42\n"
                      << "  --steps N       optional finite run with compute timing\n"
                      << "Without --steps: read 'step N' or 'quit' from stdin.\n";
            std::exit(0);
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
        else if (name == "--seed") options.initial.seed = integer(value, name, true);
        else if (name == "--dt") options.physics.dt = number(value);
        else if (name == "--softening") options.physics.softening = number(value);
        else if (name == "--G") options.physics.gravitational_constant = number(value);
        else throw std::invalid_argument("Unknown option: " + name);
    }
    if (!count_set) options.initial.count = options.initial.scenario == "solar" ? 9 : options.initial.scenario == "binary" ? 2 : 1000;
    options.physics.validate();
    if (!std::isfinite(static_cast<double>(options.steps)*options.physics.dt)) throw std::invalid_argument("Duration overflow.");
    return options;
}
} // namespace

int main(int argc, char** argv) {
    try {
        const auto options = parse_options(argc, argv);
        const auto initial = nbody::make_initial_conditions(options.initial, options.physics);
        nbody::CpuSimulation simulation(initial.state, options.physics);
        if (options.steps == 0) {
            nbody::run_live(simulation, options.initial, initial, std::cin, std::cout);
        } else {
            // The numerical loop is timed separately from diagnostics and I/O.
            const double initial_energy = nbody::diagnostics(simulation.state(), options.physics).total_energy();
            const auto start = std::chrono::steady_clock::now();
            simulation.advance(options.steps);
            const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
            const auto final = nbody::diagnostics(simulation.state(), options.physics);
            std::cout << std::setprecision(17)
                      << "backend=cpu-sequential\ncount=" << simulation.state().size()
                      << "\nsteps=" << simulation.steps() << "\ntime=" << simulation.time()
                      << "\ncompute_seconds=" << seconds << "\ninitial_energy=" << initial_energy
                      << "\nfinal_energy=" << final.total_energy() << '\n';
        }
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "nbody_cpu: " << error.what() << '\n';
        return 1;
    }
}
