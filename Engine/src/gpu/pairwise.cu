// One thread per body, with atomic updates for every pair it computes.
#include "pairwise_common.cuh"

namespace {

__global__ void pairwise_forces(PairSources sources, PairSums sums, unsigned int count,
                                double gravity, double softening_squared) {
    const unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i >= count) return;

    const PairBody first = sources.body(i);
    // We visit only j > i and update both bodies using the same distance.
    for (unsigned int j = i + 1; j < count; ++j) {
        const PairBody second = sources.body(j);
        const PairVector direction = pair_direction(first, second, gravity, softening_squared);
        sums.add(i, direction, second.mass);
        sums.add(j, direction, -first.mass);
    }
}

} // namespace

void nbody::gpu_direct_acceleration(const State& state, const Parameters& physics,
                                     Acceleration& result, int threads_per_block) {
    run_pairwise(state, physics, result, threads_per_block,
        [](PairSources sources, PairSums sums, unsigned int count, unsigned int threads,
           double gravity, double softening_squared) {
            const unsigned int blocks = (count + threads - 1) / threads;
            pairwise_forces<<<blocks, threads>>>(sources, sums, count, gravity, softening_squared);
        });
}
