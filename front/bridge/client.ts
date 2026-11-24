// Browser commands and live updates from the relay.
import type { LiveMessage, ReadyMessage } from './types'

export function connectLive(onMessage: (message: LiveMessage) => void, onError: () => void) {
  const connection = new EventSource('/api/events')
  connection.onmessage = (event) => {
    try { onMessage(JSON.parse(event.data) as LiveMessage) } catch { onError() }
  }
  connection.onerror = onError
  return () => connection.close()
}
export async function command(path: string, data: object = {}) {
  const response = await fetch(`/api/${path}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) })
  const result = await response.json()
  if (!response.ok) throw new Error(result.error ?? 'CPU command failed.')
}

/** Fixed colors and point sizes are display attributes, not dynamics. */
export function appearance(message: ReadyMessage) {
  const colors = new Float32Array(message.count * 3)
  const sizes = new Float32Array(message.count)
  const palettes = [[0.35, 0.53, 0.83], [0.62, 0.38, 0.73], [0.35, 0.65, 0.56], [0.72, 0.47, 0.31]]
  const groups = message.groups.length ? message.groups : [{ first: 0, count: message.count }]
  for (let g = 0; g < groups.length; g++) {
    const group = groups[g]
    const palette = palettes[g % palettes.length]
    const center = message.centers.slice(g * 3, g * 3 + 3)
    let extent = 1
    for (let i = group.first; i < group.first + group.count; i++) {
      extent = Math.max(extent, Math.hypot(message.positions[i * 3] - (center[0] ?? 0), message.positions[i * 3 + 1] - (center[1] ?? 0), message.positions[i * 3 + 2] - (center[2] ?? 0)))
    }
    for (let i = group.first; i < group.first + group.count; i++) {
      const r = Math.hypot(message.positions[i * 3] - (center[0] ?? 0), message.positions[i * 3 + 1] - (center[1] ?? 0), message.positions[i * 3 + 2] - (center[2] ?? 0))
      const core = Math.max(0, 1 - r / (extent * 0.4))
      const sparkle = ((i * 73) % 97) / 97
      colors[i * 3] = palette[0] * (1 - core) + core
      colors[i * 3 + 1] = palette[1] * (1 - core) + 0.72 * core
      colors[i * 3 + 2] = palette[2] * (1 - core) + 0.4 * core
      sizes[i] = 0.7 + sparkle ** 4 * 1.5 + core * 0.3
    }
  }
  return { colors, sizes }
}
