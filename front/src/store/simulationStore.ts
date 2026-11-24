// Simulation state and actions used by the interface.
import { create } from 'zustand'
import type { LiveFrame, LiveMetadata, LiveMessage, ScenarioId } from '../../bridge/types'
import { appearance, command, connectLive } from '../../bridge/client'

interface Store {
  scenario: ScenarioId
  requestedScenario: ScenarioId
  count: number
  galaxyCount: number
  metadata: LiveMetadata | null
  latestFrame: LiveFrame | null
  time: number
  isPlaying: boolean
  isLoading: boolean
  speed: number
  error: string | null
  revision: number
  selectedIndex: number | null
  focusGroup: number | null
  viewRevision: number
  connect: () => () => void
  loadScenario: (scenario: ScenarioId, count?: number, galaxies?: number) => Promise<void>
  togglePlaying: () => Promise<void>
  reset: () => Promise<void>
  setSpeed: (speed: number) => Promise<void>
  selectBody: (index: number | null) => void
  selectGroup: (group: number | null) => void
  overview: () => void
}

export const useSimulationStore = create<Store>((set, get) => {
  let activeSession = 0
  let colors = new Float32Array(), sizes = new Float32Array()
  function receive(message: LiveMessage) {
    if (message.session < activeSession) return
    activeSession = message.session
    if (message.type === 'ready') {
      const visual = appearance(message); colors = visual.colors; sizes = visual.sizes
      set({ scenario: message.scenario, requestedScenario: message.scenario,
        metadata: { scenario: message.scenario, count: message.count, radius: message.radius,
          dt: message.dt, masses: Float32Array.from(message.masses), groups: message.groups },
        latestFrame: { sequence: 0, time: 0, positions: Float32Array.from(message.positions), centers: Float32Array.from(message.centers), colors, sizes },
        time: 0, isLoading: false, error: null, selectedIndex: null, focusGroup: null,
        revision: get().revision + 1, viewRevision: get().viewRevision + 1 })
    } else if (message.type === 'state') {
      if (!get().metadata || message.positions.length !== get().metadata!.count * 3) return
      set({ latestFrame: { sequence: message.step, time: message.time,
        positions: Float32Array.from(message.positions), centers: Float32Array.from(message.centers), colors, sizes }, time: message.time })
    } else if (message.type === 'status') {
      set({ isPlaying: message.playing, isLoading: message.loading, speed: message.speed })
    } else set({ error: message.message, isPlaying: false, isLoading: false })
  }
  async function send(path: string, data: object = {}) {
    try { await command(path, data) }
    catch (error) { set({ error: error instanceof Error ? error.message : 'CPU command failed.', isLoading: false }) }
  }
  return {
    scenario: 'solar_system', requestedScenario: 'solar_system', count: 1000, galaxyCount: 2,
    metadata: null, latestFrame: null, time: 0, isPlaying: false, isLoading: false,
    speed: 1, error: null, revision: 0, selectedIndex: null, focusGroup: null, viewRevision: 0,
    connect: () => connectLive(receive, () => {
      activeSession = 0
      set({ error: 'CPU connection lost. Reconnecting…', isPlaying: false, isLoading: false })
    }),
    loadScenario: async (scenario, count = get().count, galaxies = get().galaxyCount) => {
      set({ requestedScenario: scenario, count, galaxyCount: galaxies, isLoading: true, isPlaying: false, error: null })
      await send('session', { scenario, count, galaxies })
    },
    togglePlaying: async () => {
      if (!get().metadata || get().isLoading) return
      await send(get().isPlaying ? 'pause' : 'play')
    },
    reset: async () => {
      set({ isLoading: true, isPlaying: false, error: null })
      await send('reset')
    },
    setSpeed: async (speed) => {
      if (![0.25, 0.5, 1, 2, 4].includes(speed)) return
      await send('speed', { speed })
    },
    selectBody: (index) => {
      if (index !== null && (!Number.isInteger(index) || index < 0 || index >= (get().metadata?.count ?? 9))) return
      set({ selectedIndex: index, focusGroup: null, viewRevision: get().viewRevision + 1 })
    },
    selectGroup: (group) => {
      if (group !== null && (!Number.isInteger(group) || group < 0 || group >= (get().metadata?.groups.length ?? 0))) return
      set({ focusGroup: group, selectedIndex: null, viewRevision: get().viewRevision + 1 })
    },
    overview: () => set({ focusGroup: null, selectedIndex: null, viewRevision: get().viewRevision + 1 }),
  }
})
