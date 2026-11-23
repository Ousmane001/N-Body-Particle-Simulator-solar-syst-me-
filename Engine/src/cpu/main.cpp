// Run the CPU simulation in live mode or for a fixed number of steps.
#include "nbody/benchmark.hpp"
#include "nbody/cpu.hpp"
#include "nbody/live.hpp"
#include <algorithm>
#include <iostream>
#include <utility>

int main(int argc, char** argv) {
    using namespace nbody;
    try {
        const auto options = parse_options(argc, argv);
        const auto start = Clock::now();
        auto initial = make_initial_conditions(options.initial, options.physics);
        CpuSimulation simulation(std::move(initial.state), options.physics);
        if (options.steps == 0) {
            run_live(simulation, options.initial, initial, std::cin, std::cout);
            return 0;
        }

        const auto validation_start = Clock::now();
        EnergyReport energy(diagnostics(simulation.state(), options.physics).total_energy());
        Timings timings;
        timings.validation = seconds(Clock::now() - validation_start);
        const auto interval = options.energy_every == 0 ? options.steps : options.energy_every;

        // Time each batch of steps and keep the energy checks outside that timer.
        while (simulation.steps() < options.steps) {
            const auto batch = std::min(interval, options.steps - simulation.steps());
            const auto compute_start = Clock::now();
            simulation.advance(batch);
            const auto check_start = Clock::now();
            timings.compute += seconds(check_start - compute_start);
            energy.observe(diagnostics(simulation.state(), options.physics).total_energy());
            timings.validation += seconds(Clock::now() - check_start);
        }

        timings.total = seconds(Clock::now() - start);
        return print_benchmark("cpu-sequential", options, timings, energy);
    } catch (const std::exception& error) {
        std::cerr << "nbody_cpu: " << error.what() << '\n';
        return 1;
    }
}
