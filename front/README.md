# Live CPU frontend

```sh
npm ci
npm run dev
```

This builds the C++ engine, starts the local relay and serves the interface
at http://127.0.0.1:5173/. A C++17 compiler and CMake are required.

All scenes are computed by the CPU. The only display controls are scenario,
population, galaxy count, Play/Pause, Restart, speed and camera navigation.

See the root README for the architecture and `../moteur/README.md` for the
English explanation of the numerical code.
