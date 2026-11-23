// Declare the live connection between the CPU engine and the display.
#pragma once
#include "nbody/cpu.hpp"
#include "nbody/initial_conditions.hpp"
#include <iosfwd>

namespace nbody {
// A small text protocol connects the independent executable to a local relay.
// stdout: one JSON message per line. stdin: "step N" or "quit".
void run_live(CpuSimulation& simulation, const InitialOptions& options,
              const InitialConditions& initial, std::istream& input, std::ostream& output);
} // namespace nbody
