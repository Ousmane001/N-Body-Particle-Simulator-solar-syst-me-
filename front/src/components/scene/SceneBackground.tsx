import { Stars } from '@react-three/drei'
import { useSimulationStore } from '../../store/simulationStore'
export function SceneBackground() {
  const solar = useSimulationStore((s) => s.scenario === 'solar_system')
  return <>
    <color attach="background" args={['#06080d']} />
    <Stars radius={250} depth={80} count={solar ? 1800 : 500} factor={1.2} saturation={0} fade speed={0} />
    <ambientLight intensity={0.35} />
  </>
}
