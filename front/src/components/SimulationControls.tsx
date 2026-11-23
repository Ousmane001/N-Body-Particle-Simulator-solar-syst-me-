// Show the controls that play, pause, and reset the simulation.
import { ScenarioBar } from './ScenarioBar'
import { ControlPanel } from './ControlPanel'
import { BodyNavigator } from './BodyNavigator'
import { Icon } from './Icons'
import { useSimulationStore } from '../store/simulationStore'

export function SimulationControls() {
  const scenario = useSimulationStore((s) => s.scenario)
  const loading = useSimulationStore((s) => s.isLoading)
  const count = useSimulationStore((s) => s.count)
  const galaxies = useSimulationStore((s) => s.galaxyCount)
  const error = useSimulationStore((s) => s.error)
  return <>
    <header className="simulation-header">
      <ScenarioBar />
      {scenario !== 'solar_system' && <div className="population-controls">
        <label>Bodies<select aria-label="Number of bodies" value={count} disabled={loading} onChange={(e) => void useSimulationStore.getState().loadScenario(scenario, Number(e.target.value))}>
          {[256, 512, 1000, 2000, 5000, 10000].map((n) => <option key={n} value={n}>{n.toLocaleString('en-US')}</option>)}
        </select></label>
        {scenario === 'galaxy_merger' && <label>Galaxies<select aria-label="Number of galaxies" value={galaxies} disabled={loading} onChange={(e) => void useSimulationStore.getState().loadScenario(scenario, count, Number(e.target.value))}>
          {[2, 3, 4].map((n) => <option key={n} value={n}>{n}</option>)}
        </select></label>}
      </div>}
    </header>
    {loading && <div className="loading-indicator" role="status"><span className="loading-dot" />Loading…</div>}
    {error && <div className="error-banner" role="alert"><span>{error}</span><button className="icon-button" aria-label="Dismiss message" onClick={() => useSimulationStore.setState({ error: null })}><Icon name="close" /></button></div>}
    <div className="bottom-dock"><BodyNavigator /><ControlPanel /></div>
  </>
}
