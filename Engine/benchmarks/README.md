# CPU timing

Build in Release and run, from the project root:

```sh
moteur/build/nbody_cpu --scenario cluster --count 1024 --steps 20 --dt 0.001 --softening 0.02 --G 1 --seed 42
```

`compute_seconds` measures only the integration loop. Rendering,
communication, initial state generation and energy diagnostics are excluded.
Repeat identical commands and keep the machine/compiler/build parameters
with your measurements. Do not compare sanitizer builds against Release.

For the GPU work you implement later, use the same host initial state,
precision, dt, G, softening and step count. Report device transfers separately.
