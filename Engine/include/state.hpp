// Body data, physics settings, and diagnostics.
#pragma once
#include <cstddef>
#include <vector>

namespace nbody {
struct Vec3 {
    double x = 0.0, y = 0.0, z = 0.0;
};
// Each array holds one quantity for all bodies. Index i refers to the same body in every array.
struct State {
    std::vector<double> x, y, z, vx, vy, vz, mass;
    explicit State(std::size_t count = 0);
    std::size_t size() const noexcept { return mass.size(); }
    void validate() const;
};
// CPU and GPU use the same constants in normalized units.
struct Parameters {
    double gravitational_constant = 1.0;
    // The square of this small length is added to the squared distance.
    double softening = 0.02;
    double dt = 0.001;
    void validate() const;
};
struct Acceleration {
    std::vector<double> x, y, z;
    explicit Acceleration(std::size_t count = 0) : x(count), y(count), z(count) {}
};
struct Diagnostics {
    double kinetic_energy = 0.0;
    double potential_energy = 0.0;
    Vec3 momentum, angular_momentum, center_of_mass;
    double total_energy() const noexcept { return kinetic_energy + potential_energy; }
};

Diagnostics diagnostics(const State& state, const Parameters& parameters);
} // namespace nbody
