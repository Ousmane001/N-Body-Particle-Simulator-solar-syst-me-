import { useEffect, useRef } from 'react'
import { useFrame, useThree } from '@react-three/fiber'
import { OrbitControls } from '@react-three/drei'
import type { OrbitControls as OrbitControlsImpl } from 'three-stdlib'
import * as THREE from 'three'
import { useSimulationStore } from '../../store/simulationStore'
import { SOLAR_BODIES } from './solarAppearance'

export function CameraRig() {
  const viewRevision = useSimulationStore((s) => s.viewRevision)
  const camera = useThree((s) => s.camera)
  const size = useThree((s) => s.size)
  const controlsRef = useRef<OrbitControlsImpl | null>(null)
  const transitioning = useRef(true)
  const reducedMotion = useRef(false)
  const target = useRef(new THREE.Vector3())
  const nextTarget = useRef(new THREE.Vector3())
  const desired = useRef(new THREE.Vector3())
  const difference = useRef(new THREE.Vector3())
  useEffect(() => { transitioning.current = true }, [viewRevision, size.width, size.height])
  useEffect(() => {
    const media = matchMedia('(prefers-reduced-motion: reduce)')
    const update = () => { reducedMotion.current = media.matches }
    update(); media.addEventListener('change', update)
    return () => media.removeEventListener('change', update)
  }, [])
  useFrame((_, delta) => {
    const controls = controlsRef.current
    if (!controls) return
    const { latestFrame, selectedIndex, focusGroup, scenario, metadata } = useSimulationStore.getState()
    const solar = scenario === 'solar_system'
    const body = selectedIndex === null ? null : SOLAR_BODIES[selectedIndex]
    const following = selectedIndex !== null || focusGroup !== null
    const alpha = reducedMotion.current ? 1 : 1 - Math.exp(-5 * Math.min(delta, 0.05))
    if (selectedIndex !== null) {
      const p = latestFrame?.positions
      const i = selectedIndex * 3
      if (p && i + 2 < p.length) target.current.set(p[i], p[i + 1], p[i + 2])
      else return
    } else if (focusGroup !== null && latestFrame?.centers) {
      target.current.fromArray(latestFrame.centers, focusGroup * 3)
    } else if (transitioning.current) target.current.set(0, 0, 0)
    else return
    nextTarget.current.copy(controls.target).lerp(target.current, alpha)
    difference.current.copy(nextTarget.current).sub(controls.target)
    camera.position.add(difference.current)
    controls.target.copy(nextTarget.current)
    if (transitioning.current) {
      if (following) {
        const distance = solar && body ? body.radius * (body.id === 'saturn' ? 8 : 6) : 20
        desired.current.set(distance * 0.6, -distance, distance * 0.45).add(target.current)
      } else {
        const half = THREE.MathUtils.degToRad((camera as THREE.PerspectiveCamera).fov) / 2
        const hHalf = Math.atan(Math.tan(half) * size.width / Math.max(size.height, 1))
        const radius = metadata?.radius ?? 14
        const distance = radius * 1.05 / Math.sin(Math.min(half, hHalf))
        desired.current.set(10, -14, scenario === 'star_cluster' ? 9 : 15).normalize().multiplyScalar(distance)
      }
      camera.position.lerp(desired.current, alpha)
      if (camera.position.distanceTo(desired.current) < 0.02) transitioning.current = false
    }
    controls.update()
  })
  return <OrbitControls ref={controlsRef} makeDefault enableDamping dampingFactor={0.08}
    onStart={() => { transitioning.current = false }} autoRotate={false}
    autoRotateSpeed={0.35} minDistance={0.35} maxDistance={1000} />
}
