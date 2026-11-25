// CPU force calculation with one distance evaluation per pair of bodies.
#include "cpu.hpp"
#include <algorithm>
#include <cmath>
#include <future>
#include <stdexcept>
#include <vector>

namespace nbody {

void pairwise_acceleration(const State& state, const Parameters& parameters, Acceleration& result,
                           std::size_t threads) {
    state.validate();
    parameters.validate();

    const std::size_t count = state.size();
    const std::size_t workers = std::max(std::size_t{1}, std::min(threads, count - 1));
    const double softening_squared = parameters.softening * parameters.softening;

    // Each worker has its own sums because a pair updates both bodies.
    std::vector<std::vector<Vec3>> sums(workers, std::vector<Vec3>(count));
    const auto accumulate_pairs = [&](std::size_t worker) {
        auto& local = sums[worker];
        // Early rows have more pairs, so we hand out the rows in turn.
        for (std::size_t i = worker; i + 1 < count; i += workers) {
            const double xi = state.x[i];
            const double yi = state.y[i];
            const double zi = state.z[i];
            for (std::size_t j = i + 1; j < count; ++j) {
                const double dx = state.x[j] - xi;
                const double dy = state.y[j] - yi;
                const double dz = state.z[j] - zi;
                const double r2 = dx * dx + dy * dy + dz * dz + softening_squared;
                if (!(r2 > 0.0) || !std::isfinite(r2))
                    throw std::domain_error("Invalid pair distance; use positive softening for coincident bodies.");

                const double inv_r = 1.0 / std::sqrt(r2);
                const double inv_r_cubed = inv_r * inv_r * inv_r;

                // The forces are opposite. After dividing by each body's mass,
                // its acceleration depends on the other body's mass.
                const double toward_j = (parameters.gravitational_constant * state.mass[j]) * inv_r_cubed;
                const double toward_i = (parameters.gravitational_constant * state.mass[i]) * inv_r_cubed;
                local[i].x += toward_j * dx;
                local[i].y += toward_j * dy;
                local[i].z += toward_j * dz;
                local[j].x -= toward_i * dx;
                local[j].y -= toward_i * dy;
                local[j].z -= toward_i * dz;
            }
        }
    };

    std::vector<std::future<void>> tasks;
    for (std::size_t worker = 1; worker < workers; ++worker)
        tasks.push_back(std::async(std::launch::async, accumulate_pairs, worker));
    accumulate_pairs(0);
    for (auto& task : tasks)
        task.get();

    // We combine the private sums only after all workers finish.
    result.x.resize(count);
    result.y.resize(count);
    result.z.resize(count);
    for (std::size_t i = 0; i < count; ++i) {
        Vec3 total;
        for (const auto& local : sums) {
            total.x += local[i].x;
            total.y += local[i].y;
            total.z += local[i].z;
        }
        if (!std::isfinite(total.x) || !std::isfinite(total.y) || !std::isfinite(total.z))
            throw std::overflow_error("Acceleration overflow.");
        result.x[i] = total.x;
        result.y[i] = total.y;
        result.z[i] = total.z;
    }
}

} // namespace nbody
