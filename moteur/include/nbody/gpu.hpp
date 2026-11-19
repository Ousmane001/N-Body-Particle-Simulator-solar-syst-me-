#pragma once

#include "nbody/state.hpp"
#include <cstdint>

namespace nbody {

void gpu_direct_acceleration(
    const State& state,
    const Parameters& parameters,
    Acceleration& acceleration,
    int threads_per_block
);

}