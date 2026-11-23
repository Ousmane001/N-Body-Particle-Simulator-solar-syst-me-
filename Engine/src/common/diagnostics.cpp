// Calculate the energy, momentum, and center of mass of a state.
#include "nbody/state.hpp"
#include <cmath>
#include <stdexcept>

namespace nbody {
Diagnostics diagnostics(const State& s, const Parameters& p) {
    s.validate(); p.validate();
    Diagnostics d;
    double total_mass = 0.0;
    for (std::size_t i = 0; i < s.size(); ++i) {
        const double m = s.mass[i];
        total_mass += m;
        d.kinetic_energy += 0.5 * m * (s.vx[i] * s.vx[i] + s.vy[i] * s.vy[i] + s.vz[i] * s.vz[i]);
        d.momentum.x += m * s.vx[i]; d.momentum.y += m * s.vy[i]; d.momentum.z += m * s.vz[i];
        d.center_of_mass.x += m * s.x[i]; d.center_of_mass.y += m * s.y[i]; d.center_of_mass.z += m * s.z[i];
        d.angular_momentum.x += m * (s.y[i] * s.vz[i] - s.z[i] * s.vy[i]);
        d.angular_momentum.y += m * (s.z[i] * s.vx[i] - s.x[i] * s.vz[i]);
        d.angular_momentum.z += m * (s.x[i] * s.vy[i] - s.y[i] * s.vx[i]);
        for (std::size_t j = i + 1; j < s.size(); ++j) {
            const double dx = s.x[j] - s.x[i], dy = s.y[j] - s.y[i], dz = s.z[j] - s.z[i];
            const double r2 = dx * dx + dy * dy + dz * dz + p.softening * p.softening;
            if (!(r2 > 0.0) || !std::isfinite(r2)) throw std::domain_error("Invalid pair distance in energy calculation.");
            d.potential_energy -= p.gravitational_constant * s.mass[i] * s.mass[j] / std::sqrt(r2);
        }
    }
    d.center_of_mass.x /= total_mass; d.center_of_mass.y /= total_mass; d.center_of_mass.z /= total_mass;
    for (double value : {d.kinetic_energy, d.potential_energy, d.total_energy(), d.momentum.x, d.momentum.y, d.momentum.z,
                        d.angular_momentum.x, d.angular_momentum.y, d.angular_momentum.z,
                        d.center_of_mass.x, d.center_of_mass.y, d.center_of_mass.z}) {
        if (!std::isfinite(value)) throw std::overflow_error("Diagnostics overflow.");
    }
    return d;
}
} // namespace nbody
