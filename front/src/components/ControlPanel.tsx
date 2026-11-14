import { useSimulationStore } from '../store/simulationStore'
import { Icon } from './Icons'
export function ControlPanel() {
  const playing = useSimulationStore((s) => s.isPlaying)
  const loading = useSimulationStore((s) => s.isLoading)
  const ready = useSimulationStore((s) => s.metadata !== null)
  const time = useSimulationStore((s) => s.time)
  const speed = useSimulationStore((s) => s.speed)
  return <div className="playback-bar panel">
    <button className="play-button" disabled={loading || !ready} onClick={() => void useSimulationStore.getState().togglePlaying()}
      aria-label={playing ? 'Pause' : 'Play'} title={playing ? 'Pause' : 'Play'}><Icon name={playing ? 'pause' : 'play'} size={20} /></button>
    <button className="icon-button reset-button" disabled={loading || !ready} onClick={() => void useSimulationStore.getState().reset()} aria-label="Restart" title="Restart"><Icon name="reset" /></button>
    <output className="live-time mono" aria-label="Simulation time">{time.toFixed(2)} s</output>
    <label className="speed-control"><span className="sr-only">Simulation speed</span><select disabled={loading || !ready} value={speed} onChange={(e) => void useSimulationStore.getState().setSpeed(Number(e.target.value))}>
      {[0.25, 0.5, 1, 2, 4].map((value) => <option key={value} value={value}>×{value}</option>)}
    </select></label>
  </div>
}
