// Placeholder for the advanced CUDA variant.
#include "gpu.hpp"
#include <stdexcept>

void nbody::gpu_direct_acceleration(const State&, const Parameters&, Acceleration&, int) {
    throw std::logic_error("The advanced CUDA variant is not implemented.");
}
