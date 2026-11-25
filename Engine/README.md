# Simulation engine

This engine simulates bodies moving under gravity. The frontend runs the CPU
version live, and the benchmark script runs a fixed number of steps on the
same cluster setup for each CPU or CUDA variant.

## Build

The build requires CMake 3.21 or later and a C++17 compiler. The commands run
from the root of `nbody-gpu`.

```sh
cmake -S Engine -B build
cmake --build build --parallel
```

The CPU executable is `build/nbody_cpu`. CMake adds the GPU executables when
it finds a CUDA compiler. Running a GPU variant requires the CUDA toolkit
and an NVIDIA GPU.

## Main files

- The state holds positions, velocities, masses and physics settings. [state.hpp](include/state.hpp)
- The CPU and CUDA force functions calculate gravitational acceleration. [CPU](src/cpu/naive.cpp) · [CUDA](src/gpu/naive.cu)
- The integrator advances the system using those accelerations. [SoA integration](src/common/simulation.cpp) · [AoS integration](include/naive_aos.hpp)
- The initial conditions define how bodies start in each scenario. [initial_conditions.cpp](src/common/initial_conditions.cpp)
- The diagnostics calculate energy, momentum and center of mass. [diagnostics.cpp](src/common/diagnostics.cpp)
- The main program selects live mode or a benchmark. [main.cpp](src/main.cpp)

## 1. The state

`State` stores one array per quantity.

```text
x[i], y[i], z[i]       position of body i
vx[i], vy[i], vz[i]    velocity of body i
mass[i]               mass of body i
```

All arrays have the same length and use double precision. A separate
`Acceleration` stores ax, ay and az for each body. The model uses normalized
units with G set to 1 by default.

## 2. Direct gravity

For each body `i`, we sum the acceleration caused by the other bodies `j`.

```text
d = position[j] - position[i]
r2 = dot(d, d) + epsilon * epsilon
acceleration[i] += G * mass[j] * d / (r2 * sqrt(r2))
```

The loop skips `j = i`. The target mass cancels when we divide the force by
that mass. A positive `epsilon` keeps the denominator away from zero when
bodies are close together. The calculation visits N(N−1) pairs in total, so
its cost is O(N²). Each target body has its own output, which lets CUDA assign
one thread per body.

## 3. Leapfrog integration

`CpuSimulation::step()` advances the system in three stages.

```text
KICK    velocity += 0.5 * dt * old_acceleration
DRIFT   position += dt * velocity
        compute acceleration using ALL new positions
KICK    velocity += 0.5 * dt * new_acceleration
```

The first kick uses the acceleration at the initial positions. Each step
recalculates the accelerations after all positions have changed and keeps
them for the next step. At the end of a step, positions and velocities
describe the same time. The default values are `dt = 0.001`, `epsilon = 0.02`
and `G = 1`.

## 4. Initial conditions

We shift the initial positions and velocities so the center of mass starts
at the origin with zero net momentum. Random scenarios use seed 42 by default.

- `binary` starts two equal masses on a circular orbit with softening.
- `solar` uses nine bodies with normalized masses and orbital radii.
- `cluster` samples positions uniformly in a sphere, sets the total mass to 100 and scales the velocities so `2K / |U| = 1`.
- `galaxy` places a thick spiral disk around a dominant central mass.
- `merger` starts two to four tilted disks moving toward each other.

## 5. Live communication

Without `--steps`, the executable writes a JSON `ready` message to stdout and
then reads one command per line from stdin.

```text
step 10
step 10
quit
```

`step N` performs N fixed integration steps and immediately emits a JSON
`state` message containing the current positions, time, step count, group
centers and compute duration. N must be between 1 and 1000. Messages are
flushed so the display receives them immediately. Nothing is saved to disk.

The relay requests only one batch at a time. Pause means that no new batch
is requested. Restart replaces the process with the same initial conditions.

Example from the project root.

```sh
printf 'step 10\nstep 10\nquit\n' | build/nbody_cpu --scenario solar
```

The live engine runs on the local CPU. The browser receives positions from
the relay. [live.cpp](src/common/live.cpp)

## 6. Benchmark variants

The benchmark script builds and runs the selected variant on `cluster`.
These examples use the same body count and number of steps.

```sh
scripts/benchmark.sh cpu-naive --count 1024 --steps 20
scripts/benchmark.sh cpu-coalesced-access --count 1024 --steps 20
scripts/benchmark.sh cpu-pairwise --count 1024 --steps 20 --threads 4
scripts/benchmark.sh gpu-naive --count 1024 --steps 20
scripts/benchmark.sh gpu-coalesced-access --count 1024 --steps 20
scripts/benchmark.sh gpu-optim --count 1024 --steps 20
scripts/benchmark.sh gpu-advanced-optim --count 1024 --steps 20
scripts/benchmark.sh gpu-pairwise --count 1024 --steps 20
scripts/benchmark.sh gpu-pairwise-tiled --count 1024 --steps 20
```

- `cpu-naive` and `gpu-naive` are the direct AoS baselines with one `Body` object per particle. In both cases, the CPU advances the simulation.
- `cpu-coalesced-access` uses a SoA loop designed for CPU vectorization. The live frontend uses the same implementation. [CPU implementation](src/cpu/coalesced_access.cpp)
- `cpu-pairwise` visits only pairs with `i < j`. Each thread sums its own accelerations for both bodies in a pair, then we add the private sums together. It uses one thread by default. On Slurm, request at least as many CPUs per task as you pass to `--threads`. [CPU implementation](src/cpu/pairwise.cpp)
- `gpu-coalesced-access` loads SoA source data into shared memory in tiles and reuses its GPU buffers. The CPU advances the simulation. [CUDA implementation](src/gpu/coalesced_access.cu)
- `gpu-optim` uses Houda Rachidi's 1D tiled force kernel. One thread computes the acceleration of one target body. [CUDA implementation](src/gpu/optim.cu)
- `gpu-advanced-optim` uses Houda's block reduction kernel. One block computes partial sums for one target body and reduces them to a single acceleration. [CUDA implementation](src/gpu/advanced_optim.cu)

The two variants from Houda keep the simulation state on the GPU between steps.
The CUDA variants default to 256 threads per block. The block size for
`gpu-advanced-optim` must be a power of two.

Both pairwise GPU variants compute only pairs with `i < j` and use the
same CPU integration code.

- `gpu-pairwise` assigns one body to each thread and atomically adds each pair's contribution to both bodies. [CUDA implementation](src/gpu/pairwise.cu)
- `gpu-pairwise-tiled` assigns a 16 × 16 tile of pairs to each block. The block sums contributions in shared memory before making one atomic update per body and per component. [CUDA implementation](src/gpu/pairwise_tiled.cu)

### Naive AoS baselines

`cpu-naive` and `gpu-naive` store each body's position, velocity and
mass in one `Body` object. The objects form an array of structures (AoS).
Consecutive GPU threads read the same coordinate from different objects,
so those reads are spaced by `sizeof(Body)` bytes. [CUDA strided accesses](https://docs.nvidia.com/cuda/cuda-c-best-practices-guide/index.html#strided-accesses)

Both variants use the same direct force calculation and advance the bodies
on the CPU. The GPU variant uses one thread per target body. For each force
call, it uploads the body array and reads back the accelerations. Its two
timings cover the kernel alone and the kernel with those transfers.

### Results and timing

Each run replaces `results/<variant>.json`. The summary contains `algo`,
`nbodies`, `steps`, `compute_seconds`, `compute_with_transfer_seconds`,
`simulated_time_per_step` and `energy_delta`.

- For CPU variants, both timing fields measure the initial force calculation and the integration steps.
- For `gpu-naive` and `gpu-coalesced-access`, `compute_seconds` is the sum of the CUDA force kernel timings. The second field also includes the transfers for each force call.
- For `gpu-pairwise` and `gpu-pairwise-tiled`, the two timings also include clearing the GPU acceleration arrays before each force calculation.
- For `gpu-optim` and `gpu-advanced-optim`, `compute_seconds` covers the initial force calculation and integration on the GPU. The second field also includes the initial upload.

Energy checks run outside the measured intervals, including the downloads
used to check energy in the two GPU integration variants.

### Energy checks

Total energy is the sum of kinetic and potential energy. The potential
energy uses the same softening as the forces and counts each body pair once.
`energy_delta` is the final energy minus the initial energy.

The default checks run at the start and end. `--energy-every K` adds a check
every K steps when K is positive. `--max-energy-drift X` applies
a relative limit to the largest measured change from the initial energy.
For example, `--max-energy-drift 0.001` sets a limit of 0.1%. A run that
exceeds the limit saves its JSON and exits with status 2.

## 7. Plot benchmark results

```sh
scripts/plot_benchmarks.py results/gpu-naive.json results/gpu-coalesced-access.json

# Comparison of Houda's two GPU integration variants
scripts/plot_benchmarks.py results/gpu-optim.json results/gpu-advanced-optim.json
```

The input files must share the same `nbodies` and `steps`. The script creates
one PNG per JSON in `results/plots/`. The two points show the compute-only
time and the time including transfers. The same y-axis scale is used across
the images, and each algorithm has a fixed color. Plotting requires Python 3
and gnuplot, available via `brew install gnuplot` on macOS or
`sudo apt install gnuplot` on Debian/Ubuntu.
