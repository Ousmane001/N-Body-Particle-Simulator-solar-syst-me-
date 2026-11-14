# N-Body — Live CPU

A C++17 sequential N-body engine connected to a minimal React/Three.js view.
All four scenarios are computed by the CPU while the application is running.
The interface keeps only the latest positions received from the engine.

## Start

Requirements: a C++17 compiler, CMake 3.18+, Node.js 22.12+ or 24+, and npm.
From the project directory:

```sh
cd front
npm ci
npm run dev
```

This command builds the C++ executable, starts the local communication relay,
and opens the development server at http://127.0.0.1:5173/.
The engine is an independent program: its build does not require Node.js.

## Controls

- Select Solar system, Spiral galaxy, Galaxy collision, or Star cluster.
- Choose the body count; collisions support two to four galaxies.
- Play requests new integration steps from the CPU.
- Pause stops requesting work. A small batch already running may finish.
- Restart creates the same initial state again with the same random seed.
- Speed changes the requested number of steps, never the physical time step.
- Drag to rotate, scroll to zoom, or select a planet/group to follow it.

The displayed time is **simulation time**, calculated as steps × dt.
Live display does not imply that simulation time matches wall-clock time.
The direct CPU algorithm costs O(N²), so larger populations advance more
slowly. The default is 1,000 bodies for stellar scenes. The relay adjusts
batch sizes to avoid accumulating work; it never skips integration steps.
The solar scene contains the Sun and all eight planets.

## Components

```text
moteur/              C++ state, forces, Leapfrog, initial conditions and tests
front/bridge/       Local process relay, HTTP events, client and display types
front/src/          Controls, camera, solar materials and point-cloud rendering
```

The data path is:

```text
C++ CPU process → stdout → local Node relay → HTTP event stream → browser
browser controls → HTTP commands → relay → C++ stdin
```

The relay contains no gravity or integration code. It uses one C++ process
and forwards current positions. Closing the last browser connection pauses
the calculation. The local relay listens only on 127.0.0.1:8787; Vite proxies
its `/api` routes. One local simulation session is shared by the browser tabs.

## Read the engine

Start with [moteur/README.md](moteur/README.md). The two main numerical files are:

- `moteur/src/cpu/forces.cpp`: the direct target/source loop.
- `moteur/src/cpu/simulation.cpp`: the three explicit Kick–Drift–Kick stages.

The solver uses double precision, fixed dt, Newtonian direct gravity and
softening. The teaching initial conditions use normalized units and are not
astronomical ephemerides. GPU implementation is left for the next project step.

## Build and test the engine alone

```sh
cmake -S moteur -B moteur/build -DCMAKE_BUILD_TYPE=Release
cmake --build moteur/build -j 4
ctest --test-dir moteur/build --output-on-failure
moteur/build/nbody_cpu --scenario cluster --count 256 --steps 100
```

The finite command prints compute time and energy diagnostics. It produces
no data files. The integration timer excludes setup, diagnostics and output.

## Test the live application

After building the engine, from `front/`:

```sh
npm run lint
npm run build
npm test
```

The tests run the real executable and check its text protocol, HTTP event
stream, pause/resume, restart, scenario changes, group navigation, startup
stability, connection handling and the reduced UI. No GPU is required.

## Attribution

The interface was adapted from Neural Gravity Lab by Adi, under MIT:
https://github.com/researchingadi/N-Body-Particle-Simulator

The original numerical engine is not used. The C++ engine was written for
this project. Planet textures are by Solar System Scope / INOVE, CC BY 4.0:
https://www.solarsystemscope.com/textures/
See `LICENSE`, `NOTICE.md`, and `front/public/textures/ATTRIBUTION.md`.
