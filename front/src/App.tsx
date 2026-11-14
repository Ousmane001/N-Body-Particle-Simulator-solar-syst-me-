import { useEffect } from 'react'
import { SimulationCanvas } from './components/SimulationCanvas'
import { SimulationControls } from './components/SimulationControls'
import { ErrorBoundary } from './components/ErrorBoundary'
import { useSimulationStore } from './store/simulationStore'

function App() {
  const connect = useSimulationStore((s) => s.connect)
  useEffect(() => {
    const disconnect = connect()
    const state = useSimulationStore.getState()
    if (!state.metadata && !state.isLoading) void state.loadScenario('solar_system')
    return disconnect
  }, [connect])
  return <main className="simulation-view" aria-label="N-body simulation">
    <ErrorBoundary title="The 3D scene could not start." message="Check that WebGL is enabled in your browser, then reload the page."><div className="scene-stage" aria-label="Interactive 3D scene"><SimulationCanvas /></div></ErrorBoundary>
    <SimulationControls />
  </main>
}
export default App
