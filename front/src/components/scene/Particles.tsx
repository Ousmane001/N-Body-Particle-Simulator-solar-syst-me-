// Draw the bodies as particles for the cluster and galaxy views.
import { useEffect, useMemo, useRef } from 'react'
import { useFrame } from '@react-three/fiber'
import * as THREE from 'three'
import { useSimulationStore } from '../../store/simulationStore'

const vertexShader = `
  attribute vec3 aPrevious;
  attribute vec3 aColor;
  attribute float aSize;
  uniform float uBlend;
  uniform float uSize;
  uniform float uPixelRatio;
  varying vec3 vColor;
  void main() {
    vec3 p = mix(aPrevious, position, uBlend);
    vec4 mv = modelViewMatrix * vec4(p, 1.0);
    gl_Position = projectionMatrix * mv;
    gl_PointSize = clamp(aSize * uSize * uPixelRatio * 75.0 / max(5.0, -mv.z), 1.0, 18.0 * uPixelRatio);
    vColor = aColor;
  }
`
const fragmentShader = `
  uniform float uBrightness;
  varying vec3 vColor;
  void main() {
    vec2 p = gl_PointCoord * 2.0 - 1.0;
    float r = dot(p, p);
    if (r > 1.0) discard;
    float alpha = exp(-r * 4.0) * 0.28 + exp(-r * 20.0) * 0.72;
    gl_FragColor = vec4(vColor * uBrightness, alpha);
    #include <colorspace_fragment>
  }
`

/** One point cloud / draw call. Arrays are uploaded only on a new CPU update;
 * interpolation is done by the GPU, with no per-star React components. */
export function Particles() {
  const count = useSimulationStore((s) => s.metadata?.count ?? 0)
  const revision = useSimulationStore((s) => s.revision)
  const resources = useMemo(() => {
    const geometry = new THREE.BufferGeometry()
    geometry.setAttribute('position', new THREE.BufferAttribute(new Float32Array(count * 3), 3).setUsage(THREE.DynamicDrawUsage))
    geometry.setAttribute('aPrevious', new THREE.BufferAttribute(new Float32Array(count * 3), 3).setUsage(THREE.DynamicDrawUsage))
    geometry.setAttribute('aColor', new THREE.BufferAttribute(new Float32Array(count * 3), 3))
    geometry.setAttribute('aSize', new THREE.BufferAttribute(new Float32Array(count), 1))
    geometry.setDrawRange(0, count)
    const material = new THREE.ShaderMaterial({ vertexShader, fragmentShader, transparent: true,
      depthWrite: false, blending: THREE.AdditiveBlending, toneMapped: false,
      uniforms: { uBlend: { value: 1 }, uSize: { value: 1 }, uBrightness: { value: 1 }, uPixelRatio: { value: 1 } } })
    return { geometry, material }
  }, [count])
  const previous = useRef<Float32Array | null>(null)
  const lastRevision = useRef(-1)
  const lastFrame = useRef<Float32Array | null>(null)
  const lastUpload = useRef(0)
  const initialized = useRef(false)
  useEffect(() => {
    initialized.current = false; previous.current = null; lastFrame.current = null
    return () => { resources.geometry.dispose(); resources.material.dispose() }
  }, [resources])
  useFrame((state) => {
    const store = useSimulationStore.getState()
    const frame = store.latestFrame
    if (!frame || frame.positions.length !== count * 3) return
    const changedSession = lastRevision.current !== revision
    if (frame.positions !== lastFrame.current || changedSession) {
      const pos = resources.geometry.getAttribute('position') as THREE.BufferAttribute
      const prev = resources.geometry.getAttribute('aPrevious') as THREE.BufferAttribute
      pos.array.set(frame.positions)
      prev.array.set(!changedSession && previous.current ? previous.current : frame.positions)
      pos.needsUpdate = true; prev.needsUpdate = true
      if (!initialized.current || changedSession) {
        const colors = resources.geometry.getAttribute('aColor') as THREE.BufferAttribute
        const sizes = resources.geometry.getAttribute('aSize') as THREE.BufferAttribute
        if (frame.colors) colors.array.set(frame.colors)
        else for (let i = 0; i < count; i++) colors.setXYZ(i, 0.65, 0.76, 0.95)
        if (frame.sizes) sizes.array.set(frame.sizes)
        else (sizes.array as Float32Array).fill(1)
        colors.needsUpdate = true; sizes.needsUpdate = true
        initialized.current = true
      }
      previous.current = frame.positions; lastFrame.current = frame.positions
      lastRevision.current = revision; lastUpload.current = state.clock.elapsedTime
    }
    resources.material.uniforms.uBlend.value = store.isPlaying ? Math.min(1, (state.clock.elapsedTime - lastUpload.current) / 0.05) : 1
    resources.material.uniforms.uSize.value = 1.7
    resources.material.uniforms.uBrightness.value = Math.min(1, Math.sqrt(5000 / Math.max(count, 1)))
    resources.material.uniforms.uPixelRatio.value = state.gl.getPixelRatio()
  })
  return <points geometry={resources.geometry} material={resources.material} frustumCulled={false} />
}
