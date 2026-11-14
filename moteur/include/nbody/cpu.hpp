#pragma once
#include "nbody/state.hpp"
#include <cstdint>

namespace nbody {
// Direct target/source loop, ascending indices, self interaction omitted.
void direct_acceleration(const State& state, const Parameters& parameters, Acceleration& result);
Diagnostics diagnostics(const State& state, const Parameters& parameters);

// Positions AND velocities are synchronized at each integer time step.
class CpuSimulation {
public:
    CpuSimulation(State initial, Parameters parameters);
    void step();
    void advance(std::uint64_t steps);
    const State& state() const noexcept { return state_; }
    const Parameters& parameters() const noexcept { return parameters_; }
    std::uint64_t steps() const noexcept { return steps_; }
    double time() const noexcept { return static_cast<double>(steps_) * parameters_.dt; }
private:
    State state_;
    Parameters parameters_;
    Acceleration acceleration_;
    std::uint64_t steps_ = 0;
};
} // namespace nbody
