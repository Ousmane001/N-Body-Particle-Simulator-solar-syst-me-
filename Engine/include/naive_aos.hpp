// Body layout and CPU integration shared by the two AoS baselines.
#pragma once

#include "benchmark.hpp"
#include <algorithm>
#include <stdexcept>
#include <vector>

namespace nbody {

// We keep the position, velocity, and mass of each body together.
struct Body {
    Vec3 position;
    Vec3 velocity;
    double mass;
};

inline void kick(std::vector<Body>& bodies, const std::vector<Vec3>& accelerations, double dt) {
    for (std::size_t i = 0; i < bodies.size(); ++i) {
        auto& velocity = bodies[i].velocity;
        velocity.x += dt * accelerations[i].x;
        velocity.y += dt * accelerations[i].y;
        velocity.z += dt * accelerations[i].z;
    }
}

template <typename CalculateForces>
int run_aos_benchmark(const char* algo, const Options& options, CalculateForces calculate_forces) {
    if (options.steps == 0)
        throw std::invalid_argument("The AoS benchmark requires --steps.");

    // The usual initial conditions give both layouts the same starting state.
    State checkpoint = make_initial_conditions(options.initial, options.physics).state;
    std::vector<Body> bodies(checkpoint.size());
    std::vector<Vec3> accelerations(bodies.size());
    for (std::size_t i = 0; i < bodies.size(); ++i) {
        bodies[i] = {{checkpoint.x[i], checkpoint.y[i], checkpoint.z[i]},
                     {checkpoint.vx[i], checkpoint.vy[i], checkpoint.vz[i]}, checkpoint.mass[i]};
    }

    EnergyReport energy(diagnostics(checkpoint, options.physics).total_energy());
    const bool gpu = options.block_size != 0;
    const double dt = options.physics.dt;
    const double half_dt = 0.5 * dt;
    const auto interval = options.energy_every == 0 ? options.steps : options.energy_every;

    auto start = Clock::now();
    calculate_forces(bodies, options.physics, accelerations);
    Timings timings{seconds(Clock::now() - start)};

    for (std::uint64_t done = 0; done < options.steps;) {
        const auto batch = std::min(interval, options.steps - done);
        start = Clock::now();
        for (std::uint64_t step = 0; step < batch; ++step) {
            // Leapfrog uses the old acceleration for the first half kick.
            kick(bodies, accelerations, half_dt);
            for (auto& body : bodies) {
                body.position.x += dt * body.velocity.x;
                body.position.y += dt * body.velocity.y;
                body.position.z += dt * body.velocity.z;
            }
            calculate_forces(bodies, options.physics, accelerations);
            kick(bodies, accelerations, half_dt);
        }
        timings.compute += seconds(Clock::now() - start);
        done += batch;

        // The existing energy check reads separate arrays. This copy is outside the timer.
        for (std::size_t i = 0; i < bodies.size(); ++i) {
            const auto& body = bodies[i];
            checkpoint.x[i] = body.position.x;
            checkpoint.y[i] = body.position.y;
            checkpoint.z[i] = body.position.z;
            checkpoint.vx[i] = body.velocity.x;
            checkpoint.vy[i] = body.velocity.y;
            checkpoint.vz[i] = body.velocity.z;
        }
        energy.observe(diagnostics(checkpoint, options.physics).total_energy());
    }

    // The CUDA version reports its own kernel and transfer times.
    if (gpu) return print_benchmark(algo, options, take_gpu_force_timings(), energy);
    timings.with_transfer = timings.compute;
    return print_benchmark(algo, options, timings, energy);
}

} // namespace nbody
