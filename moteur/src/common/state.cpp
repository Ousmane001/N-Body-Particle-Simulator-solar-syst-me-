#include "nbody/state.hpp"
#include <cmath>
#include <limits>
#include <stdexcept>

namespace nbody {
State::State(std::size_t n) : x(n), y(n), z(n), vx(n), vy(n), vz(n), mass(n, 1.0) {}
void State::validate() const {
    const auto n = size();
    if (n == 0) throw std::invalid_argument("At least one body is required.");
    for (const auto* values : {&x, &y, &z, &vx, &vy, &vz, &mass}) {
        if (values->size() != n) throw std::invalid_argument("State arrays have different lengths.");
        for (double value : *values) if (!std::isfinite(value)) throw std::invalid_argument("State contains a non-finite value.");
    }
    double total_mass = 0.0;
    for (double m : mass) {
        if (m <= 0.0) throw std::invalid_argument("Masses must be positive.");
        total_mass += m;
    }
    if (!std::isfinite(total_mass)) throw std::overflow_error("Total mass overflow.");
}
void Parameters::validate() const {
    if (!std::isfinite(dt) || dt <= 0.0) throw std::invalid_argument("dt must be finite and positive.");
    if (!std::isfinite(gravitational_constant) || gravitational_constant < 0.0) throw std::invalid_argument("G must be finite and nonnegative.");
    if (!std::isfinite(softening) || softening < 0.0 || !std::isfinite(softening * softening)) throw std::invalid_argument("Softening must be finite, nonnegative, with a finite square.");
}
} // namespace nbody
