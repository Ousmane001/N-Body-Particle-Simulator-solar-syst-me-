// Version CPU optimisee en Structure of Arrays (SoA).
// Meme algorithme direct O(N^2) que naive.cpp, mais ecrit pour permettre
// au compilateur de vectoriser la boucle (SIMD) et d'eviter les relectures inutiles.
#include "cpu.hpp"
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

    const double G = parameters.gravitational_constant;
    const double epsilon_squared = parameters.softening * parameters.softening;

    // On recupere des pointeurs bruts avec __restrict__ pour indiquer au compilateur
    // que les tableaux d'entree et de sortie ne se chevauchent pas en memoire.
    const double* __restrict__ x = state.x.data();
    const double* __restrict__ y = state.y.data();
    const double* __restrict__ z = state.z.data();
    const double* __restrict__ mass = state.mass.data();
    double* __restrict__ ax_out = acceleration.x.data();
    double* __restrict__ ay_out = acceleration.y.data();
    double* __restrict__ az_out = acceleration.z.data();

    for (std::size_t i = 0; i < body_count; ++i) {
        // On charge la position cible dans des variables locales pour eviter
        // de relire state.x[i], state.y[i], state.z[i] a chaque iteration j.
        const double xi = x[i];
        const double yi = y[i];
        const double zi = z[i];

        double ax = 0.0;
        double ay = 0.0;
        double az = 0.0;
        bool invalid_distance = false;

        // We split the source range around i so the inner loop can skip self-interaction.
        const auto accumulate = [&](std::size_t first, std::size_t last) {
#if defined(__clang__)
            #pragma clang loop vectorize(enable) interleave(enable)
#elif defined(__GNUC__)
            #pragma GCC ivdep
#endif
            for (std::size_t j = first; j < last; ++j) {
                const double dx = x[j] - xi;
                const double dy = y[j] - yi;
                const double dz = z[j] - zi;

                const double distance_squared = dx * dx + dy * dy + dz * dz + epsilon_squared;
                invalid_distance |= !(distance_squared > 0.0) || !std::isfinite(distance_squared);
                const double inverse_distance = 1.0 / std::sqrt(distance_squared);
                const double factor = G * mass[j] * (inverse_distance * inverse_distance * inverse_distance);

                ax += factor * dx;
                ay += factor * dy;
                az += factor * dz;
            }
        };
        accumulate(0, i);
        accumulate(i + 1, body_count);

        // Distance errors are reported after the SIMD loop.
        if (invalid_distance)
            throw std::domain_error("Invalid pair distance; use positive softening for coincident bodies.");
        if (!std::isfinite(ax) || !std::isfinite(ay) || !std::isfinite(az))
            throw std::overflow_error("Acceleration overflow.");

        ax_out[i] = ax;
        ay_out[i] = ay;
        az_out[i] = az;
    }
}

} // namespace nbody
