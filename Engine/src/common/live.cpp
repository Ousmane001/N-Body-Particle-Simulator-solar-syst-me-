// Read live commands and send the current CPU state to the display as JSON.
#include "nbody/live.hpp"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <iomanip>
#include <istream>
#include <limits>
#include <locale>
#include <ostream>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace nbody {
namespace {
struct Group { std::size_t first, count; std::string name, color; };
std::vector<Group> groups_for(const InitialOptions& options, std::size_t count) {
    if (options.scenario == "solar") return {};
    if (options.scenario != "merger") return {{0, count, options.scenario == "galaxy" ? "Galaxy" : "Cluster", "#9bbfff"}};
    const char* colors[] = {"#9bbfff", "#e0b6df", "#b9ded0", "#e8c6a3"};
    std::vector<Group> groups;
    std::size_t first = 0;
    for (std::size_t g = 0; g < options.galaxies; ++g) {
        const auto size = count/options.galaxies + (g < count%options.galaxies ? 1 : 0);
        groups.push_back({first, size, std::string("Galaxy ") + static_cast<char>('A' + g), colors[g]});
        first += size;
    }
    return groups;
}
void positions(std::ostream& output, const State& state) {
    output << '[';
    for (std::size_t i = 0; i < state.size(); ++i) {
        if (i) output << ',';
        output << state.x[i] << ',' << state.y[i] << ',' << state.z[i];
    }
    output << ']';
}
void centers(std::ostream& output, const State& state, const std::vector<Group>& groups) {
    output << '[';
    for (std::size_t g = 0; g < groups.size(); ++g) {
        double mass = 0.0; Vec3 center;
        for (std::size_t i = groups[g].first; i < groups[g].first + groups[g].count; ++i) {
            mass += state.mass[i];
            center.x += state.mass[i]*state.x[i]; center.y += state.mass[i]*state.y[i]; center.z += state.mass[i]*state.z[i];
        }
        if (g) output << ',';
        output << center.x/mass << ',' << center.y/mass << ',' << center.z/mass;
    }
    output << ']';
}
void send_state(std::ostream& output, const CpuSimulation& simulation,
                const std::vector<Group>& groups, double compute_seconds) {
    output << "{\"type\":\"state\",\"time\":" << simulation.time() << ",\"step\":" << simulation.steps()
           << ",\"computeSeconds\":" << compute_seconds << ",\"positions\":";
    positions(output, simulation.state()); output << ",\"centers\":";
    centers(output, simulation.state(), groups);
    output << "}\n" << std::flush;
    if (!output) throw std::runtime_error("The live connection was closed.");
}
} // namespace
void run_live(CpuSimulation& simulation, const InitialOptions& options,
              const InitialConditions& initial, std::istream& input, std::ostream& output) {
    output.imbue(std::locale::classic());
    output << std::setprecision(std::numeric_limits<double>::max_digits10);
    const auto& state = simulation.state();
    const auto groups = groups_for(options, state.size());
    double radius = 1.0;
    for (std::size_t i = 0; i < state.size(); ++i) radius = std::max(radius, std::hypot(state.x[i], state.y[i], state.z[i]));
    output << "{\"type\":\"ready\",\"scenario\":\"" << initial.frontend_scenario
           << "\",\"count\":" << state.size() << ",\"radius\":" << radius + 1.0 << ",\"dt\":" << simulation.parameters().dt << ",\"masses\":[";
    for (std::size_t i = 0; i < state.size(); ++i) { if (i) output << ','; output << state.mass[i]; }
    output << "],\"groups\":[";
    for (std::size_t g = 0; g < groups.size(); ++g) {
        if (g) output << ',';
        output << "{\"name\":\"" << groups[g].name << "\",\"color\":\"" << groups[g].color
               << "\",\"first\":" << groups[g].first << ",\"count\":" << groups[g].count << '}';
    }
    output << "],\"positions\":"; positions(output, state);
    output << ",\"centers\":"; centers(output, state, groups);
    output << ",\"time\":0,\"step\":0}\n" << std::flush;
    if (!output) throw std::runtime_error("The live connection was closed.");

    // Wait for work rather than running ahead of the display. Pausing means
    // the relay stops requesting steps; the scientific state stays in memory.
    std::string line;
    while (std::getline(input, line)) {
        std::istringstream command(line);
        std::string action, extra;
        command >> action;
        if (action == "quit" && !(command >> extra)) return;
        unsigned int steps = 0;
        if (action != "step" || !(command >> steps) || steps < 1 || steps > 1000 || (command >> extra))
            throw std::invalid_argument("Expected 'step N' (1..1000) or 'quit'.");
        const auto start = std::chrono::steady_clock::now();
        simulation.advance(steps);
        const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();
        send_state(output, simulation, groups, seconds);
    }
}
} // namespace nbody
