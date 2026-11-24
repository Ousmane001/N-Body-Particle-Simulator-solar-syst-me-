// Initial positions, velocities, and masses for each scenario.
#include "initial_conditions.hpp"
#include <algorithm>
#include <cmath>
#include <limits>
#include <stdexcept>

namespace nbody {
namespace {
constexpr double tau = 6.283185307179586476925286766559;
// SplitMix64 produces uniform values, and Box-Muller gives us normal values.
class Random {
    std::uint64_t state_;
public:
    explicit Random(std::uint64_t seed) : state_(seed) {}
    double uniform() {
        auto z = (state_ += UINT64_C(0x9e3779b97f4a7c15));
        z = (z ^ (z >> 30)) * UINT64_C(0xbf58476d1ce4e5b9);
        z = (z ^ (z >> 27)) * UINT64_C(0x94d049bb133111eb);
        z ^= z >> 31;
        return static_cast<double>(z >> 11) * 0x1.0p-53;
    }
    double normal() {
        const double u = std::max(uniform(), std::numeric_limits<double>::min());
        return std::sqrt(-2.0 * std::log(u)) * std::cos(tau * uniform());
    }
};
double circular_speed(double radius, double central_mass, const Parameters& p) {
    const double r2 = radius * radius;
    return std::sqrt(p.gravitational_constant * central_mass * r2 / std::pow(r2 + p.softening * p.softening, 1.5));
}
State disk(std::size_t count, Random& random, const Parameters& parameters) {
    State s(count);
    s.mass[0] = 100.0;
    for (std::size_t i = 1; i < count; ++i) {
        const double radius = 0.5 + 8.0 * std::sqrt(random.uniform());
        const double arm = std::floor(random.uniform() * 3.0) * tau / 3.0;
        const double angle = arm + 0.65 * radius + 0.12 * random.normal();
        s.mass[i] = 10.0 / static_cast<double>(count - 1);
        s.x[i] = radius * std::cos(angle); s.y[i] = radius * std::sin(angle);
        s.z[i] = 0.08 * random.normal();
        const double speed = circular_speed(radius, s.mass[0], parameters);
        s.vx[i] = -speed * std::sin(angle); s.vy[i] = speed * std::cos(angle);
    }
    recenter(s);
    return s;
}
} // namespace

void recenter(State& s) {
    s.validate();
    double mass = 0.0;
    Vec3 position, velocity;
    for (std::size_t i = 0; i < s.size(); ++i) {
        mass += s.mass[i];
        position.x += s.mass[i] * s.x[i]; position.y += s.mass[i] * s.y[i]; position.z += s.mass[i] * s.z[i];
        velocity.x += s.mass[i] * s.vx[i]; velocity.y += s.mass[i] * s.vy[i]; velocity.z += s.mass[i] * s.vz[i];
    }
    // We subtract the mean position and velocity, weighted by mass.
    for (std::size_t i = 0; i < s.size(); ++i) {
        s.x[i] -= position.x / mass; s.y[i] -= position.y / mass; s.z[i] -= position.z / mass;
        s.vx[i] -= velocity.x / mass; s.vy[i] -= velocity.y / mass; s.vz[i] -= velocity.z / mass;
    }
    s.validate();
}

InitialConditions make_initial_conditions(const InitialOptions& o, const Parameters& p) {
    p.validate();
    if (o.count < 2 || o.count > 1000000) throw std::invalid_argument("Initial count must be between 2 and 1000000.");
    Random random(o.seed);
    InitialConditions initial;
    if (o.scenario == "binary") {
        if (o.count != 2) throw std::invalid_argument("The binary scenario contains exactly two bodies.");
        initial.state = State(2);
        auto& s = initial.state;
        s.x[0] = -0.5; s.x[1] = 0.5;
        const double omega = std::sqrt(p.gravitational_constant * 2.0 / std::pow(1.0 + p.softening * p.softening, 1.5));
        s.vy[0] = -0.5 * omega; s.vy[1] = 0.5 * omega;
        initial.frontend_scenario = "star_cluster";
    } else if (o.scenario == "solar") {
        if (o.count != 9) throw std::invalid_argument("The solar scenario contains exactly nine bodies.");
        initial.state = State(9);
        auto& s = initial.state;
        s.mass[0] = 1000.0;
        // The solar system uses normalized masses and orbital radii.
        const double radii[] = {1.8, 2.7, 3.7, 4.8, 6.4, 8.5, 10.8, 13.0};
        const double masses[] = {0.001, 0.002, 0.003, 0.002, 0.25, 0.15, 0.08, 0.08};
        for (std::size_t i = 1; i < 9; ++i) {
            const double angle = tau * static_cast<double>(i - 1) / 8.0 + 0.2;
            const double r = radii[i - 1];
            s.mass[i] = masses[i - 1];
            s.x[i] = r * std::cos(angle); s.y[i] = r * std::sin(angle);
            const double speed = circular_speed(r, s.mass[0] + s.mass[i], p);
            s.vx[i] = -speed * std::sin(angle); s.vy[i] = speed * std::cos(angle);
        }
        initial.frontend_scenario = "solar_system";
    } else if (o.scenario == "cluster") {
        initial.state = State(o.count);
        auto& s = initial.state;
        double total_weight = 0.0;
        for (std::size_t i = 0; i < s.size(); ++i) {
            // The cube root spreads the positions uniformly through the sphere's volume.
            const double r = 4.0 * std::cbrt(random.uniform());
            const double cosine = 2.0 * random.uniform() - 1.0;
            const double sine = std::sqrt(std::max(0.0, 1.0 - cosine * cosine));
            const double angle = tau * random.uniform();
            s.x[i] = r * sine * std::cos(angle); s.y[i] = r * sine * std::sin(angle); s.z[i] = r * cosine;
            s.vx[i] = random.normal(); s.vy[i] = random.normal(); s.vz[i] = random.normal();
            s.mass[i] = 0.5 + random.uniform();
            total_weight += s.mass[i];
        }
        // We keep the cluster's total mass at 100 when the body count changes.
        const double mass_scale = 100.0 / total_weight;
        for (double& mass : s.mass) mass *= mass_scale;
        recenter(s);
        const auto d = diagnostics(s, p);
        // Scaling all velocities by this factor gives an initial 2K / |U| ratio of 1.
        const double scale = d.kinetic_energy > 0.0 ? std::sqrt(-d.potential_energy / (2.0 * d.kinetic_energy)) : 0.0;
        for (std::size_t i = 0; i < s.size(); ++i) { s.vx[i] *= scale; s.vy[i] *= scale; s.vz[i] *= scale; }
        initial.frontend_scenario = "star_cluster";
    } else if (o.scenario == "galaxy") {
        initial.state = disk(o.count, random, p);
        initial.frontend_scenario = "disk_galaxy";
    } else if (o.scenario == "merger") {
        if (o.galaxies < 2 || o.galaxies > 4 || o.count < 2 * o.galaxies) throw std::invalid_argument("A merger needs 2-4 galaxies and at least two bodies per galaxy.");
        initial.state = State(o.count);
        auto& s = initial.state;
        std::size_t offset = 0;
        for (std::size_t g = 0; g < o.galaxies; ++g) {
            // Any leftover bodies go to the first galaxies so the total matches the requested count.
            const auto n = o.count / o.galaxies + (g < o.count % o.galaxies ? 1 : 0);
            const auto galaxy = disk(n, random, p);
            const double angle = tau * static_cast<double>(g) / static_cast<double>(o.galaxies);
            const double tilt = g % 2 == 0 ? 0.25 : -0.55;
            const double c = std::cos(tilt), t = std::sin(tilt);
            for (std::size_t j = 0; j < n; ++j) {
                const auto i = offset + j;
                s.mass[i] = galaxy.mass[j];
                s.x[i] = galaxy.x[j] + 12.0 * std::cos(angle);
                s.y[i] = c * galaxy.y[j] - t * galaxy.z[j] + 12.0 * std::sin(angle);
                s.z[i] = t * galaxy.y[j] + c * galaxy.z[j];
                s.vx[i] = galaxy.vx[j] - 0.6 * std::cos(angle);
                s.vy[i] = c * galaxy.vy[j] - t * galaxy.vz[j] - 0.6 * std::sin(angle);
                s.vz[i] = t * galaxy.vy[j] + c * galaxy.vz[j];
            }
            offset += n;
        }
        initial.frontend_scenario = "galaxy_merger";
    } else throw std::invalid_argument("Unknown scenario: " + o.scenario);
    recenter(initial.state);
    return initial;
}
} // namespace nbody
