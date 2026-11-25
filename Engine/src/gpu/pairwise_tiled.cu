// One CUDA block per 2D tile, with local sums before atomic updates.
#include "pairwise_common.cuh"

namespace {

constexpr unsigned int tile_size = 16;

__global__ void pairwise_tiled_forces(PairSources sources, PairSums sums, unsigned int count,
                                      double gravity, double softening_squared) {
    const unsigned int row_start = blockIdx.y * tile_size;
    const unsigned int col_start = blockIdx.x * tile_size;
    if (row_start > col_start) return;
    const bool diagonal = row_start == col_start;

    __shared__ PairBody rows[tile_size], cols[tile_size];
    __shared__ PairVector pairs[tile_size][tile_size];

    for (unsigned int k = threadIdx.x; k < tile_size; k += blockDim.x) {
        rows[k] = row_start + k < count ? sources.body(row_start + k) : PairBody{};
        cols[k] = col_start + k < count ? sources.body(col_start + k) : PairBody{};
    }
    __syncthreads();

    // Each shared entry holds the part of the acceleration common to both bodies.
    // The diagonal tiles keep only i < j. Empty entries contribute zero.
    for (unsigned int k = threadIdx.x; k < tile_size * tile_size; k += blockDim.x) {
        const unsigned int row = k / tile_size;
        const unsigned int col = k % tile_size;
        const unsigned int i = row_start + row;
        const unsigned int j = col_start + col;
        pairs[row][col] = i < count && j < count && i < j
            ? pair_direction(rows[row], cols[col], gravity, softening_squared)
            : PairVector{};
    }
    __syncthreads();

    // Off-diagonal tiles have two groups of bodies. On the diagonal we combine
    // the row and column sums for each body before writing back.
    const unsigned int bodies_in_tile = diagonal ? tile_size : 2 * tile_size;
    for (unsigned int slot = threadIdx.x; slot < bodies_in_tile; slot += blockDim.x) {
        const bool row_body = slot < tile_size;
        const unsigned int k = slot % tile_size;
        const unsigned int body = (row_body ? row_start : col_start) + k;
        if (body >= count) continue;

        PairVector total{};
        for (unsigned int other = 0; other < tile_size; ++other) {
            if (row_body) {
                const PairVector pair = pairs[k][other];
                total.x += cols[other].mass * pair.x;
                total.y += cols[other].mass * pair.y;
                total.z += cols[other].mass * pair.z;
            }
            if (!row_body || diagonal) {
                const PairVector pair = pairs[other][k];
                total.x -= rows[other].mass * pair.x;
                total.y -= rows[other].mass * pair.y;
                total.z -= rows[other].mass * pair.z;
            }
        }
        sums.add(body, total, 1.0);
    }
}

} // namespace

void nbody::gpu_direct_acceleration(const State& state, const Parameters& physics,
                                     Acceleration& result, int threads_per_block) {
    run_pairwise(state, physics, result, threads_per_block,
        [](PairSources sources, PairSums sums, unsigned int count, unsigned int threads,
           double gravity, double softening_squared) {
            const unsigned int tiles = (count + tile_size - 1) / tile_size;
            const dim3 grid(tiles, tiles);
            pairwise_tiled_forces<<<grid, threads>>>(sources, sums, count, gravity, softening_squared);
        });
}
