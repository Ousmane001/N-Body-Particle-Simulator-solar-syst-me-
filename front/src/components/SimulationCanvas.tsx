// Set up the 3D scene and choose how to draw the current scenario.
import { Canvas } from '@react-three/fiber'
import { EffectComposer, Bloom } from '@react-three/postprocessing'
import { SceneBackground } from './scene/SceneBackground'
import { Particles } from './scene/Particles'
import { CameraRig } from './scene/CameraRig'
import { SolarSystem } from './scene/SolarSystem'
import { useSimulationStore } from '../store/simulationStore'
export function SimulationCanvas() {
  const scenario = useSimulationStore((s) => s.scenario)
  const ready = useSimulationStore((s) => s.metadata !== null)
  return <Canvas camera={{ position: [18, -25, 23], up: [0, 0, 1], fov: 43, near: 0.01, far: 2000 }}
    gl={{ antialias: true, powerPreference: 'high-performance' }} dpr={[1, 1.5]}>
    <SceneBackground />
    {ready && (scenario === 'solar_system' ? <SolarSystem /> : <Particles />)}
    <CameraRig />
    {<EffectComposer multisampling={0}>
      <Bloom luminanceThreshold={1} luminanceSmoothing={0.4} intensity={0.5} mipmapBlur radius={0.65} />
    </EffectComposer>}
  </Canvas>
}
