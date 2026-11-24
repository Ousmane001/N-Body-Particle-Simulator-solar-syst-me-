// Placeholder for the optimized CPU variant.
#include "cpu.hpp"
#include <stdexcept>

void nbody::direct_acceleration(const State&, const Parameters&, Acceleration&) {
    throw std::logic_error("Guys, don't forget to implement an optim verison with cpu for the report pls :) ");
}
