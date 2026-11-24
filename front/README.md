# Live CPU frontend

The frontend displays the real-time positions calculated by the CPU engine.

```sh
npm ci
npm run dev
```

This builds the C++ engine, starts the local relay and serves the interface
at http://127.0.0.1:5173/. A C++17 compiler and CMake are required.

All scenes are computed by the CPU. The only display controls are scenario,
population, galaxy count, Play/Pause, Restart, speed and camera navigation.

The [project README](../README.md) describes the architecture, and the
[engine guide](../Engine/README.md) explains the numerical code.
