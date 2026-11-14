import { Suspense, useEffect, useMemo, useRef } from 'react'
import { useFrame } from '@react-three/fiber'
import { Html, Line, useTexture } from '@react-three/drei'
import * as THREE from 'three'
import { useSimulationStore } from '../../store/simulationStore'
import { SOLAR_BODIES } from './solarAppearance'

function Surface({ index }: { index: number }) {
  const body = SOLAR_BODIES[index]
  const texture = useTexture(`/textures/${body.texture}`)
  useEffect(() => {
    texture.colorSpace = THREE.SRGBColorSpace
    texture.anisotropy = 4
    texture.needsUpdate = true
  }, [texture])

  return body.id === 'sun'
    ? <meshBasicMaterial map={texture} color={[2.1, 1.45, 0.75]} toneMapped={false} />
    : <meshStandardMaterial map={texture} roughness={body.id === 'earth' ? 0.65 : 0.94} metalness={0} />
}

function EarthClouds() {
  const clouds = useTexture('/textures/2k_earth_clouds.jpg')
  return (
    <mesh scale={1.012}>
      <sphereGeometry args={[1, 48, 32]} />
      <meshStandardMaterial alphaMap={clouds} transparent opacity={0.48} depthWrite={false} />
    </mesh>
  )
}

function SaturnRings() {
  const texture = useTexture('/textures/2k_saturn_ring_alpha.png')
  const geometry = useMemo(() => {
    const ring = new THREE.RingGeometry(1.35, 2.3, 128)
    const positions = ring.getAttribute('position')
    const uv = ring.getAttribute('uv') as THREE.BufferAttribute
    for (let i = 0; i < positions.count; i++) {
      const radius = Math.hypot(positions.getX(i), positions.getY(i))
      uv.setXY(i, (radius - 1.35) / (2.3 - 1.35), 0.5)
    }
    return ring
  }, [])
  useEffect(() => {
    texture.colorSpace = THREE.SRGBColorSpace
    texture.needsUpdate = true
    return () => geometry.dispose()
  }, [geometry, texture])
  return (
    <mesh geometry={geometry} rotation={[-Math.PI / 2, 0, 0]}>
      <meshStandardMaterial map={texture} transparent side={THREE.DoubleSide} opacity={0.92} roughness={1} depthWrite={false} />
    </mesh>
  )
}

// A view-dependent atmospheric rim; no simulation or trajectory computation.
const atmosphereVertex = `
  varying vec3 vNormal;
  varying vec3 vView;
  void main() {
    vec4 p = modelViewMatrix * vec4(position, 1.0);
    vNormal = normalize(normalMatrix * normal);
    vView = normalize(-p.xyz);
    gl_Position = projectionMatrix * p;
  }
`
const atmosphereFragment = `
  uniform vec3 tint;
  uniform float strength;
  varying vec3 vNormal;
  varying vec3 vView;
  void main() {
    float rim = pow(1.0 - max(dot(normalize(vNormal), normalize(vView)), 0.0), 3.0);
    gl_FragColor = vec4(tint, rim * strength);
  }
`

function Atmosphere({ sun }: { sun: boolean }) {
  const uniforms = useMemo(() => ({
    tint: { value: new THREE.Color(sun ? '#ff9f36' : '#559dff') },
    strength: { value: sun ? 0.8 : 0.65 },
  }), [sun])
  return (
    <mesh scale={sun ? 1.14 : 1.06}>
      <sphereGeometry args={[1, 48, 32]} />
      <shaderMaterial vertexShader={atmosphereVertex} fragmentShader={atmosphereFragment} uniforms={uniforms} transparent blending={THREE.AdditiveBlending} depthWrite={false} />
    </mesh>
  )
}

function Body({ index }: { index: number }) {
  const body = SOLAR_BODIES[index]
  const initial = useSimulationStore.getState().latestFrame?.positions
  const group = useRef<THREE.Group>(null)
  const spin = useRef<THREE.Group>(null)
  const selected = useSimulationStore((s) => s.selectedIndex === index)

  useFrame((_, delta) => {
    const { latestFrame, isPlaying } = useSimulationStore.getState()
    const position = latestFrame?.positions
    if (group.current && position) {
      const alpha = 1 - Math.exp(-18 * Math.min(delta, 0.05))
      group.current.position.x += (position[index * 3] - group.current.position.x) * alpha
      group.current.position.y += (position[index * 3 + 1] - group.current.position.y) * alpha
      group.current.position.z += (position[index * 3 + 2] - group.current.position.z) * alpha
    }
    // Surface rotation is decorative and pauses along with playback.
    if (spin.current && isPlaying) spin.current.rotation.y += Math.min(delta, 0.05) * 0.12
  })

  return (
    <group ref={group} position={[initial?.[index * 3] ?? 0, initial?.[index * 3 + 1] ?? 0, initial?.[index * 3 + 2] ?? 0]}>
      <group rotation={[Math.PI / 2, 0, body.tilt]} scale={body.radius}>
        <group ref={spin}>
          <mesh onClick={(event) => {
            event.stopPropagation()
            const store = useSimulationStore.getState()
            store.selectBody(index)
          }}>
            <sphereGeometry args={[1, 64, 48]} />
            <Suspense fallback={<meshStandardMaterial color={body.color} emissive={body.id === 'sun' ? body.color : '#000000'} />}>
              <Surface index={index} />
            </Suspense>
          </mesh>
          {body.id === 'earth' && <Suspense fallback={null}><EarthClouds /></Suspense>}
        </group>
        {(body.id === 'sun' || body.id === 'earth') && <Atmosphere sun={body.id === 'sun'} />}
        {body.id === 'saturn' && <Suspense fallback={null}><SaturnRings /></Suspense>}
      </group>
      {body.id === 'sun' && <pointLight color="#fff0d8" intensity={4} decay={0} />}
      {<Html position={[0, 0, body.radius + 0.22]} center zIndexRange={[10, 0]} style={{ pointerEvents: 'none' }}>
        <span className={`celestial-label ${selected ? 'celestial-label--selected' : ''}`}>{body.name}</span>
      </Html>}
    </group>
  )
}

export function SolarSystem() {
  const rings = useMemo(() => SOLAR_BODIES.slice(1).map((body) =>
    Array.from({ length: 193 }, (_, i): [number, number, number] => {
      const angle = (i / 192) * Math.PI * 2
      return [Math.cos(angle) * body.orbit, Math.sin(angle) * body.orbit, 0]
    }),
  ), [])

  return (
    <group>
      {rings.map((points, i) => <Line key={i} points={points} color="#6b819f" transparent opacity={0.24} lineWidth={0.7} />)}
      {SOLAR_BODIES.map((body, index) => <Body key={body.name} index={index} />)}
    </group>
  )
}
