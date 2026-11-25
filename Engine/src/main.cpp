// Entry point for live mode and benchmark runs.
#include "benchmark.hpp"
#include "cpu.hpp"
#include "live.hpp"
#include <algorithm>
#include <iostream>
#include <utility>

#ifdef NBODY_GPU_FORCE_VARIANT
#include "gpu.hpp"

namespace {
// CUDA timing messages go to stderr so stdout contains the JSON result.
class ForceLog {
public:
    ForceLog() : flags_(std::cout.flags()), precision_(std::cout.precision()),
                 original_(std::cout.rdbuf(std::clog.rdbuf())) {}
    ~ForceLog() {
        std::cout.rdbuf(original_);
        std::cout.flags(flags_);
        std::cout.precision(precision_);
    }

private:
    std::ios::fmtflags flags_;
    std::streamsize precision_;
    std::streambuf* original_;
};
} // namespace
#endif

int main(int argc, char** argv) {
    using namespace nbody;
#ifdef NBODY_GPU_FORCE_VARIANT
    constexpr auto backend = NBODY_GPU_FORCE_VARIANT;
    constexpr auto program = backend;
    constexpr bool gpu = true;
#elif defined(NBODY_CPU_PAIRWISE)
    constexpr auto backend = "cpu-pairwise";
    constexpr auto program = "nbody_cpu_pairwise";
    constexpr bool gpu = false;
#else
    constexpr auto backend = "cpu-coalesced-access";
    constexpr auto program = "nbody_cpu";
    constexpr bool gpu = false;
#endif
    try {
#ifdef NBODY_CPU_PAIRWISE
        const auto options = parse_options(argc, argv, gpu, true);
#else
        const auto options = parse_options(argc, argv, gpu);
#endif
        auto initial = make_initial_conditions(options.initial, options.physics);
#ifdef NBODY_GPU_FORCE_VARIANT
        // The CPU advances time and calls the GPU whenever it needs new accelerations.
        CpuSimulation simulation(std::move(initial.state), options.physics,
            [block_size = options.block_size](const State& state, const Parameters& physics, Acceleration& result) {
                const ForceLog log;
                gpu_direct_acceleration(state, physics, result, static_cast<int>(block_size));
            });
#else
        const auto initial_compute_start = Clock::now();
#ifdef NBODY_CPU_PAIRWISE
        CpuSimulation simulation(std::move(initial.state), options.physics,
            [threads = options.threads](const State& state, const Parameters& physics, Acceleration& result) {
                pairwise_acceleration(state, physics, result, threads);
            });
#else
        CpuSimulation simulation(std::move(initial.state), options.physics);
#endif
        Timings timings{seconds(Clock::now() - initial_compute_start)};
        if (options.steps == 0) {
            run_live(simulation, options.initial, initial, std::cin, std::cout);
            return 0;
        }
#endif

        EnergyReport energy(diagnostics(simulation.state(), options.physics).total_energy());
        const auto interval = options.energy_every == 0 ? options.steps : options.energy_every;

        // We check the energy after each timed batch.
        while (simulation.steps() < options.steps) {
            const auto batch = std::min(interval, options.steps - simulation.steps());
#ifndef NBODY_GPU_FORCE_VARIANT
            const auto compute_start = Clock::now();
#endif
            simulation.advance(batch);
#ifndef NBODY_GPU_FORCE_VARIANT
            timings.compute += seconds(Clock::now() - compute_start);
#endif
            energy.observe(diagnostics(simulation.state(), options.physics).total_energy());
        }

#ifdef NBODY_GPU_FORCE_VARIANT
        return print_benchmark(backend, options, take_gpu_force_timings(), energy);
#else
        timings.with_transfer = timings.compute;
        return print_benchmark(backend, options, timings, energy);
#endif
    } catch (const std::exception& error) {
        std::cerr << program << ": " << error.what() << '\n';
        return 1;
    }
}
