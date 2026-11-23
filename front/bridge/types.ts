// Define the messages used by the browser and the live relay.
export type ScenarioId = 'solar_system' | 'disk_galaxy' | 'galaxy_merger' | 'star_cluster'
export interface GroupInfo { name: string; color: string; first: number; count: number }
export interface LiveMetadata {
  scenario: ScenarioId
  count: number
  radius: number
  dt: number
  masses: Float32Array
  groups: GroupInfo[]
}
export interface LiveFrame {
  sequence: number
  time: number
  positions: Float32Array
  centers: Float32Array
  colors: Float32Array
  sizes: Float32Array
}
export interface ReadyMessage {
  type: 'ready'
  session: number
  scenario: ScenarioId
  count: number
  radius: number
  dt: number
  masses: number[]
  groups: GroupInfo[]
  positions: number[]
  centers: number[]
  time: number
  step: number
}
export interface StateMessage {
  type: 'state'
  session: number
  positions: number[]
  centers: number[]
  time: number
  step: number
}
export type LiveMessage = ReadyMessage | StateMessage |
  { type: 'status'; session: number; playing: boolean; loading: boolean; speed: number } |
  { type: 'error'; session: number; message: string }
export const SCENARIOS = [
  { id: 'solar_system', label: 'Solar system', icon: 'solar' },
  { id: 'disk_galaxy', label: 'Spiral galaxy', icon: 'galaxy' },
  { id: 'galaxy_merger', label: 'Galaxy collision', icon: 'merger' },
  { id: 'star_cluster', label: 'Star cluster', icon: 'cluster' },
] as const
