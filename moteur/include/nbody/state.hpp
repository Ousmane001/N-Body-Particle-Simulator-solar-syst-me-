#pragma once
#include <cstddef>
#include <vector>

namespace nbody {
struct Vec3 {
    double x = 0.0, y = 0.0, z = 0.0;
};
// Structure of arrays: x[i] is the x position of body i, and so on.
struct State {
    std::vector<double> x, y, z, vx, vy, vz, mass;
    explicit State(std::size_t count = 0);
    std::size_t size() const noexcept { return mass.size(); }
    void validate() const;
};
// Shared numerical conventions for the force calculation and integrator.
struct Parameters {
    double gravitational_constant = 1.0;
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
} // namespace nbody
