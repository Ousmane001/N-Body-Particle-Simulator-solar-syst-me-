// Text protocol between the CPU engine and the display relay.
#pragma once
#include "cpu.hpp"
#include "initial_conditions.hpp"
#include <iosfwd>

namespace nbody {
// stdout: one JSON message per line. stdin: "step N" or "quit".
void run_live(CpuSimulation& simulation, const InitialOptions& options,
              const InitialConditions& initial, std::istream& input, std::ostream& output);
} // namespace nbody
