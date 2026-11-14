# Understanding the CPU engine

This directory is an independent C++17 program. The code, comments and
commands are in English. There is one force algorithm and one integrator.

## Suggested reading order

1. `include/nbody/state.hpp` describes the data.
2. `src/cpu/forces.cpp` calculates acceleration.
3. `src/cpu/simulation.cpp` advances time.
4. `src/common/initial_conditions.cpp` creates starting positions and velocities.
5. `src/cpu/main.cpp` selects a live or finite run.
6. `src/common/live.cpp` handles communication with the display.

The first three files contain the core needed to understand the numerical
method. Communication and initial scene generation are separate from it.

## 1. The state

`State` is a **structure of arrays**:

```text
x[i], y[i], z[i]       position of body i
vx[i], vy[i], vz[i]    velocity of body i
mass[i]               mass of body i
```

All arrays have the same length. All values are doubles. Masses are positive
and remain constant. A separate `Acceleration` holds ax, ay and az for each
body. Units are normalized; G defaults to 1.

This layout makes the data flow explicit and can later be copied into
corresponding device arrays.

## 2. Direct gravity: forces.cpp

For one target body i, visit every source body j:

```text
d = position[j] - position[i]
r2 = dot(d, d) + epsilon * epsilon
acceleration[i] += G * mass[j] * d / (r2 * sqrt(r2))
```

Skip j = i: a body does not attract itself. The target mass is absent because
acceleration is force divided by that mass. Softening epsilon keeps the force
finite when bodies are very close.

The outer loop writes one acceleration entry. Different target indices do
not write to the same entry. This is the natural place to start your own
naive GPU implementation: reason about what one target body needs to read
and what it alone must write. Keep the CPU implementation as your reference.

The direct method visits N(N−1) directed pairs: its cost is O(N²).

## 3. Leapfrog KDK: simulation.cpp

`CpuSimulation::step()` contains three explicit stages:

```text
KICK    velocity += 0.5 * dt * old_acceleration
DRIFT   position += dt * velocity
        compute acceleration using ALL new positions
KICK    velocity += 0.5 * dt * new_acceleration
```

The initial acceleration is computed in the constructor. After a complete
step, positions and velocities describe the same integer time. The new
acceleration is kept for the next step.

All bodies must finish the drift before new forces are evaluated. Preserving
this ordering will matter when you parallelize the implementation yourself.
The physical dt is fixed; display speed changes how often steps are requested.

Defaults: dt = 0.001, epsilon = 0.02, G = 1. A smaller dt may be necessary for
more demanding initial states. Live mode never changes dt automatically.

## 4. Initial conditions

All states are generated in C++, then centered in position and velocity.
Random states use a defined generator and a fixed default seed of 42.

- `binary`: two equal masses on a circular orbit consistent with softening.
- `solar`: nine bodies in the display order, with teaching-model masses and radii.
- `cluster`: a uniform sphere, total mass 100, with velocities scaled to 2K/|U| = 1.
- `galaxy`: a thick spiral disk around a dominant central mass.
- `merger`: two to four inclined disks moving towards each other initially.

Every subsequent movement comes from gravity and Leapfrog. These starting
states are educational models rather than exact equilibrium distributions
or astronomical observations. Use the same generated host state when you
compare CPU and your future GPU implementation.

## 5. Live communication

Run the executable without `--steps`. It writes a JSON `ready` message to
stdout, then waits on stdin. Each line is one command:

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
Diagnostics are not recomputed for every display update because energy also
costs O(N²).

To try the protocol from a terminal, from the project root:

```sh
printf 'step 10\nstep 10\nquit\n' | moteur/build/nbody_cpu --scenario solar
```

The live display is local CPU only. The browser communicates with the relay;
it does not run or import any numerical C++ code.

## 6. Finite runs and validation

```sh
cmake -S moteur -B moteur/build -DCMAKE_BUILD_TYPE=Release
cmake --build moteur/build -j 4
ctest --test-dir moteur/build --output-on-failure
moteur/build/nbody_cpu --scenario cluster --count 1024 --steps 20
```

`--steps N` performs a finite run and prints timing and energy values. Only
integration steps are timed; setup, diagnostics and I/O are outside the timer.
Use Release builds and identical parameters for performance comparisons.

The 19 CTest checks cover analytical forces, softening, input validation,
free motion, a circular orbit over ten periods, second-order convergence,
energy, momentum, center of mass, angular momentum, time reversibility,
reproducible starting states and command-line validation.

For memory and undefined-behavior checks:

```sh
cmake -S moteur -B moteur/build-sanitize -DCMAKE_BUILD_TYPE=Debug -DNBODY_SANITIZERS=ON
cmake --build moteur/build-sanitize -j 4
ctest --test-dir moteur/build-sanitize --output-on-failure
```

`src/cuda/` is reserved for your own implementation. No GPU kernel is included.
