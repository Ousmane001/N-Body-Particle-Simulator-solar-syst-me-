# N-Body Simulation

This project simulates bodies moving under gravity. The React/Three.js interface
displays the CPU simulation live. A separate benchmark runs the same star
cluster on CPU and CUDA and records the computation times.

## 1. Install the tools

The engine needs a C++17 compiler and CMake 3.21 or later. The live interface
uses Node.js 24 and npm. The plot script uses Python 3 and gnuplot.

### macOS

On a fresh Mac, the first command opens the installer for the compiler and
Git. After it finishes, the second command installs Homebrew. [Homebrew installation](https://docs.brew.sh/Installation)

```sh
xcode-select --install
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

If `brew` is missing from the terminal after installation, the installer prints
a `brew shellenv` command to add it to the path. [Homebrew setup](https://docs.brew.sh/Installation)

```sh
brew install cmake node@24 python gnuplot
export PATH="$(brew --prefix node@24)/bin:$PATH"
```

### Ubuntu 24.04

```sh
sudo apt update
sudo apt install git build-essential cmake curl ca-certificates python3 gnuplot
```

For the frontend, nvm installs Node.js 24 and npm in the current user's home
directory. [nvm installation](https://github.com/nvm-sh/nvm#install--update-script)

```sh
export NVM_DIR="$HOME/.nvm"
mkdir -p "$NVM_DIR"
curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.41.0/install.sh | bash
. "$NVM_DIR/nvm.sh"
nvm install 24
```

## 2. Clone and run the CPU benchmark

```sh
git clone https://github.com/Ousmane001/N-Body-Particle-Simulator-solar-syst-me-.git nbody-gpu
cd nbody-gpu

scripts/benchmark.sh cpu-naive --count 1024 --steps 20
```

The script builds the AoS CPU baseline, runs the `cluster` scenario and
writes `results/cpu-naive.json`. For a manual build, the
executables go into `build/`.

```sh
cmake -S Engine -B build
cmake --build build --parallel
```

## 3. Start the live interface

From the repository root.

```sh
cd front
npm ci
npm run dev
```

The startup command builds the engine and starts the local relay and
frontend. The default address is [http://127.0.0.1:5173/](http://127.0.0.1:5173/).
It offers a solar system, star cluster, spiral galaxy and galaxy collision.
The displayed time is simulated time, calculated as the number of steps
times the length of one step.

### Optional frontend checks

These commands run from `front/` after `npm ci` and once `../build/nbody_cpu`
exists. The `npm test` command runs the live relay and
browser interaction checks. [Relay checks](front/scripts/test-live.mjs) · [Browser checks](front/scripts/test-ui.mjs)

```sh
npm run lint
npm run build
npm test
```

## 4. Run the CUDA benchmarks

CUDA benchmarks require a compatible NVIDIA GPU, driver and CUDA toolkit.
On Ubuntu, NVIDIA provides the driver instructions and the APT repository
setup for the installed OS version. [NVIDIA Linux setup guide](https://docs.nvidia.com/cuda/cuda-installation-guide-linux/)

Once the NVIDIA APT repository is configured, these commands install the
toolkit and check that the driver and compiler are available.

```sh
sudo apt update
sudo apt install cuda-toolkit
export PATH="/usr/local/cuda/bin:$PATH"
nvidia-smi
nvcc --version
```

From the repository root, the CUDA runs use the same number of bodies and
steps as the CPU run above.

```sh
scripts/benchmark.sh gpu-naive --count 1024 --steps 20
scripts/benchmark.sh gpu-coalesced-access --count 1024 --steps 20
scripts/benchmark.sh gpu-optim --count 1024 --steps 20
scripts/benchmark.sh gpu-advanced-optim --count 1024 --steps 20
```

## 5. Plot the results

From the repository root, this command plots the result from the CPU benchmark.

```sh
scripts/plot_benchmarks.py results/cpu-naive.json
```

After the CUDA runs, the same script can compare the results. The JSON
files must have the same body count and step count.

```sh
scripts/plot_benchmarks.py results/cpu-naive.json results/gpu-naive.json \
  results/gpu-coalesced-access.json results/gpu-optim.json results/gpu-advanced-optim.json
```

The script saves one PNG per input in `results/plots/`. Each line joins the
compute-only time and the time including transfers. CPU variants use shades
of blue, and GPU variants use warmer colors. The y-axis scale is shared
across the images from the same run.

## Project layout

- `Engine/` contains the force calculations, integration and benchmark output. [Engine guide](Engine/README.md)
- `front/` contains the React interface and the relay that starts the CPU engine. [Frontend guide](front/README.md)
- `scripts/` contains the benchmark runner and the plot script.

The engine guide covers the force equation, the integration steps, the CUDA
variants and the timing and energy measurements. [Numerical implementation](Engine/README.md#2-direct-gravity)

## Attribution

The interface was adapted from Adi's Neural Gravity Lab under the MIT
license. [Original project](https://github.com/researchingadi/N-Body-Particle-Simulator)

Planet textures are by Solar System Scope / INOVE under CC BY 4.0.
[Texture credits](front/public/textures/ATTRIBUTION.md)
