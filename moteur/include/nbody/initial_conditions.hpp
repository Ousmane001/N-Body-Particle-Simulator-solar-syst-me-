#pragma once
#include "nbody/state.hpp"
#include <cstdint>
#include <string>

namespace nbody {
struct InitialOptions {
    std::string scenario = "solar";
    std::size_t count = 9;
    std::size_t galaxies = 2;
    std::uint64_t seed = 42;
};
struct InitialConditions {
    State state;
    std::string frontend_scenario;
};
InitialConditions make_initial_conditions(const InitialOptions& options, const Parameters& parameters);
void recenter(State& state);
} // namespace nbody
