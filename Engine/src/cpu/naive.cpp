// Direct CPU forces with one object per body.
#include "naive_aos.hpp"
#include <cmath>
#include <iostream>

namespace {
void calculate_forces(const std::vector<nbody::Body>& bodies, const nbody::Parameters& physics,
                      std::vector<nbody::Vec3>& accelerations) {
    const double epsilon_squared = physics.softening * physics.softening;
    // We visit every source body for each target, skipping self-interactions.
    for (std::size_t i = 0; i < bodies.size(); ++i) {
        const auto& target = bodies[i].position;
        nbody::Vec3 sum{};
        for (std::size_t j = 0; j < bodies.size(); ++j) {
            if (i == j) continue;
            const auto& source = bodies[j];
            const double dx = source.position.x - target.x;
            const double dy = source.position.y - target.y;
            const double dz = source.position.z - target.z;
            const double r2 = dx * dx + dy * dy + dz * dz + epsilon_squared;
            if (!(r2 > 0.0) || !std::isfinite(r2))
                throw std::domain_error("Invalid pair distance.");
            const double inverse_r = 1.0 / std::sqrt(r2);
            const double factor = physics.gravitational_constant * source.mass *
                                  (inverse_r * inverse_r * inverse_r);
            sum.x += factor * dx;
            sum.y += factor * dy;
            sum.z += factor * dz;
        }
        if (!std::isfinite(sum.x) || !std::isfinite(sum.y) || !std::isfinite(sum.z))
            throw std::overflow_error("Acceleration overflow.");
        accelerations[i] = sum;
    }
}
} // namespace

int main(int argc, char** argv) {
    try {
        const auto options = nbody::parse_options(argc, argv);
        return nbody::run_aos_benchmark("cpu-naive", options, calculate_forces);
    } catch (const std::exception& error) {
        std::cerr << "cpu-naive: " << error.what() << '\n';
        return 1;
    }
}
