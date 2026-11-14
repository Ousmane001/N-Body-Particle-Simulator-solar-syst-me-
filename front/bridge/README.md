# Live CPU connection

- `server.mjs` starts one local C++ process and forwards its JSON lines over HTTP events.
- `client.ts` receives those events and sends Play/Pause/Restart/Speed commands.
- `types.ts` describes the metadata and current positions consumed by the renderer.
- `data/solar-bodies.json` contains static names, textures and visual radii only.

There are no force calculations in this directory. The C++ executable owns
positions, velocities, masses, physical parameters and the integration clock.
The renderer only interpolates incoming positions for a smoother display.

The relay retains the initial metadata and the most recent update for a new
connection. It does not retain a trajectory. It allows only one outstanding
work request and pauses when the last browser disconnects.

The live endpoints are `/api/events`, `/api/session`, `/api/play`, `/api/pause`,
`/api/reset`, `/api/speed` and `/api/health`. They are local-only and are
proxied through Vite. Their commands cannot select an arbitrary executable.
