import { SCENARIOS } from '../../bridge/types'
import { useSimulationStore } from '../store/simulationStore'
import { Icon } from './Icons'
export function ScenarioBar() {
  const selected = useSimulationStore((s) => s.requestedScenario)
  const loading = useSimulationStore((s) => s.isLoading)
  return <nav className="scenario-bar" aria-label="Scenarios">
    {SCENARIOS.map((scenario) => <button key={scenario.id} aria-pressed={selected === scenario.id}
      className={selected === scenario.id ? 'scenario-tab active' : 'scenario-tab'}
      disabled={loading} onClick={() => void useSimulationStore.getState().loadScenario(scenario.id)}>
      <Icon name={scenario.icon} /><span>{scenario.label}</span>
    </button>)}
  </nav>
}
