// Calculate the acceleration of each body from all the other bodies on the CPU.
#include "nbody/cpu.hpp"
#include <cmath>
#include <stdexcept>

namespace nbody {
void direct_acceleration(const State& state, const Parameters& parameters,
                         Acceleration& acceleration) {
    state.validate();
    parameters.validate();
    const std::size_t body_count = state.size();
    acceleration.x.resize(body_count);
    acceleration.y.resize(body_count);
    acceleration.z.resize(body_count);
    const double epsilon_squared = parameters.softening * parameters.softening;

    // i is the target body. Each iteration writes only acceleration[i].
    // This outer loop is the natural starting point for parallelization.
    for (std::size_t i = 0; i < body_count; ++i) {
        double ax = 0.0, ay = 0.0, az = 0.0;
        for (std::size_t j = 0; j < body_count; ++j) {
            if (i == j) continue; // A body does not attract itself.

            // Displacement from the target i towards the source j.
            const double dx = state.x[j] - state.x[i];
            const double dy = state.y[j] - state.y[i];
            const double dz = state.z[j] - state.z[i];
            const double distance_squared = dx*dx + dy*dy + dz*dz + epsilon_squared;
            if (!(distance_squared > 0.0) || !std::isfinite(distance_squared))
                throw std::domain_error("Invalid pair distance; use positive softening for coincident bodies.");

            const double inverse_distance = 1.0 / std::sqrt(distance_squared);
            const double inverse_distance_cubed = inverse_distance * inverse_distance * inverse_distance;
            // a = F / m_i: the target mass cancels, leaving the source mass.
            const double factor = parameters.gravitational_constant * state.mass[j] * inverse_distance_cubed;
            ax += factor * dx;
            ay += factor * dy;
            az += factor * dz;
        }
        if (!std::isfinite(ax) || !std::isfinite(ay) || !std::isfinite(az))
            throw std::overflow_error("Acceleration overflow.");
        acceleration.x[i] = ax;
        acceleration.y[i] = ay;
        acceleration.z[i] = az;
    }
}
} // namespace nbody
