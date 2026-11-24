// Leapfrog integration using kick, drift, and kick steps.
#include "cpu.hpp"
#include <cmath>
#include <limits>
#include <stdexcept>
#include <utility>

namespace nbody {
CpuSimulation::CpuSimulation(State initial, Parameters parameters, ForceCalculation calculate)
    : state_(std::move(initial)), parameters_(parameters), calculate_(std::move(calculate)),
      acceleration_(state_.size()) {
    // We need the initial acceleration for the first kick.
    calculate_(state_, parameters_, acceleration_);
}

void CpuSimulation::step() {
    if (steps_ == std::numeric_limits<std::uint64_t>::max() ||
        !std::isfinite(static_cast<double>(steps_ + 1) * parameters_.dt))
        throw std::overflow_error("Simulation time overflow.");
    const double dt = parameters_.dt;
    const double half_dt = 0.5 * dt;

    // 1. KICK: advance every velocity by half a time step.
    for (std::size_t i = 0; i < state_.size(); ++i) {
        state_.vx[i] += half_dt * acceleration_.x[i];
        state_.vy[i] += half_dt * acceleration_.y[i];
        state_.vz[i] += half_dt * acceleration_.z[i];
    }
    // 2. DRIFT: move every body using its half-step velocity.
    for (std::size_t i = 0; i < state_.size(); ++i) {
        state_.x[i] += dt * state_.vx[i];
        state_.y[i] += dt * state_.vy[i];
        state_.z[i] += dt * state_.vz[i];
    }
    // We update every position before calculating the new acceleration.
    calculate_(state_, parameters_, acceleration_);

    // 3. KICK: finish the velocity update at the new positions.
    for (std::size_t i = 0; i < state_.size(); ++i) {
        state_.vx[i] += half_dt * acceleration_.x[i];
        state_.vy[i] += half_dt * acceleration_.y[i];
        state_.vz[i] += half_dt * acceleration_.z[i];
    }
    state_.validate();
    ++steps_;
}

void CpuSimulation::advance(std::uint64_t count) {
    if (count > std::numeric_limits<std::uint64_t>::max() - steps_)
        throw std::overflow_error("Step counter overflow.");
    for (std::uint64_t i = 0; i < count; ++i) step();
}
} // namespace nbody
