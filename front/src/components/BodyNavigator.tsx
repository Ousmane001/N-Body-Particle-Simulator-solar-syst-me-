// Let the user select a body to follow in the simulation.
import { useSimulationStore } from '../store/simulationStore'
import { SOLAR_BODIES } from './scene/solarAppearance'
import { Icon } from './Icons'
export function BodyNavigator() {
  const solar = useSimulationStore((s) => s.scenario === 'solar_system')
  const ready = useSimulationStore((s) => s.metadata !== null)
  const selected = useSimulationStore((s) => s.selectedIndex)
  const focus = useSimulationStore((s) => s.focusGroup)
  // Keep this reference stable while the CPU is starting.
  const groups = useSimulationStore((s) => s.metadata?.groups)
  return <nav className="body-navigation" aria-label={solar ? 'Explore planets' : 'Explore star groups'}>
    <button className={selected === null && focus === null ? 'body-choice active' : 'body-choice'} aria-pressed={selected === null && focus === null} onClick={() => useSimulationStore.getState().overview()}>
      <Icon name="overview" /><span>Overview</span>
    </button>
    {solar ? SOLAR_BODIES.map((body, index) => <button key={body.id} disabled={!ready} className={selected === index ? 'body-choice active' : 'body-choice'} aria-pressed={selected === index} onClick={() => useSimulationStore.getState().selectBody(index)}>
      <span className={`planet-thumbnail ${body.id === 'saturn' ? 'saturn' : ''}`} style={{ backgroundImage: `url(/textures/${body.texture})`, backgroundColor: body.color }} aria-hidden="true" />{body.name}
    </button>) : groups?.map((group, index) => <button key={group.name} className={focus === index ? 'body-choice active' : 'body-choice'} aria-pressed={focus === index} onClick={() => useSimulationStore.getState().selectGroup(index)}>
      <span className="group-dot" style={{ color: group.color, background: group.color }} aria-hidden="true" />{group.name}
    </button>)}
  </nav>
}
