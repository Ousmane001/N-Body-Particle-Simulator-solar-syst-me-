// CPU force calculation and simulation step interface.
#pragma once
#include "state.hpp"
#include <cstdint>
#include <functional>

namespace nbody {
// Direct target/source loop, ascending indices, self interaction omitted.
void direct_acceleration(const State& state, const Parameters& parameters, Acceleration& result);

// Positions and velocities describe the same time after each full step.
class CpuSimulation {
public:
    using ForceCalculation = std::function<void(const State&, const Parameters&, Acceleration&)>;

    CpuSimulation(State initial, Parameters parameters, ForceCalculation calculate = direct_acceleration);
    void step();
    void advance(std::uint64_t steps);
    const State& state() const noexcept { return state_; }
    const Parameters& parameters() const noexcept { return parameters_; }
    std::uint64_t steps() const noexcept { return steps_; }
    double time() const noexcept { return static_cast<double>(steps_) * parameters_.dt; }
private:
    State state_;
    Parameters parameters_;
    ForceCalculation calculate_;
    Acceleration acceleration_;
    std::uint64_t steps_ = 0;
};
} // namespace nbody
