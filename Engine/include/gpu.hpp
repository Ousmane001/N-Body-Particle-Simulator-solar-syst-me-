// GPU force calculation for a single simulation state.
#pragma once

#include "state.hpp"

namespace nbody {

void gpu_direct_acceleration(
    const State& state,
    const Parameters& parameters,
    Acceleration& acceleration,
    int threads_per_block
);

} // namespace nbody
