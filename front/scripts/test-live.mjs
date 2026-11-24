// Tests for the live CPU protocol and relay.
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { EventSource } from 'undici'
import { fileURLToPath } from 'node:url'
import { createLiveServer } from '../bridge/server.mjs'
const binary = fileURLToPath(new URL('../../build/nbody_cpu', import.meta.url))
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
async function until(predicate, timeout = 5000) {
  const end = Date.now() + timeout
  while (!predicate()) { assert.ok(Date.now() < end, 'Timed out waiting for live data'); await wait(10) }
}
for (const [scenario, count, groups] of [['binary', 2, 1], ['solar', 9, 0], ['cluster', 64, 1], ['galaxy', 64, 1], ['merger', 65, 3]]) {
  const output = execFileSync(binary, ['--scenario', scenario, '--count', String(count), '--galaxies', '3'], { input: 'step 3\nstep 2\nquit\n', encoding: 'utf8', timeout: 10000 })
  const messages = output.trim().split('\n').map((line) => JSON.parse(line))
  assert.deepEqual(messages.map((m) => m.type), ['ready', 'state', 'state'])
  assert.equal(messages[0].count, count)
  assert.equal(messages[0].groups.length, groups)
  assert.equal(messages[0].masses.length, count)
  assert.equal(messages[1].step, 3); assert.equal(messages[2].step, 5)
  assert.equal(messages[2].time, 0.005)
  for (const m of messages) {
    assert.equal(m.positions.length, count * 3)
    assert.ok(m.positions.every(Number.isFinite))
    assert.equal(m.centers.length, groups * 3)
  }
  assert.notDeepEqual(messages[0].positions, messages[2].positions)
}
assert.throws(() => execFileSync(binary, [], { input: 'step 0\n', stdio: 'pipe' }), (error) => error.status === 1)
const relay = createLiveServer({ binary, port: 0 })
let events
try {
  const address = await relay.listen()
  const base = `http://127.0.0.1:${address.port}`
  const messages = []
  events = new EventSource(`${base}/api/events`)
  events.onmessage = (event) => messages.push(JSON.parse(event.data))
  await until(() => messages.some((m) => m.type === 'status'))
  async function post(path, data = {}) {
    const response = await fetch(`${base}/api/${path}`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) })
    assert.equal(response.status, 200, await response.clone().text())
    return response.json()
  }
  await post('session', { scenario: 'solar_system', count: 9, galaxies: 2 })
  await until(() => messages.some((m) => m.type === 'ready'))
  const initial = messages.find((m) => m.type === 'ready')
  assert.equal(initial.time, 0)
  await wait(120)
  assert.equal(messages.filter((m) => m.type === 'state').length, 0, 'Paused CPU must not advance')
  await post('play')
  await until(() => messages.filter((m) => m.type === 'state').length >= 2)
  await post('pause'); await wait(120)
  const last = messages.filter((m) => m.type === 'state').at(-1)
  await wait(120)
  assert.equal(messages.filter((m) => m.type === 'state').at(-1).step, last.step)
  await post('speed', { speed: 4 })
  await until(() => messages.filter((m) => m.type === 'status').at(-1).speed === 4)
  await post('reset')
  await until(() => messages.some((m) => m.type === 'ready' && m.session > initial.session))
  const reset = messages.filter((m) => m.type === 'ready').at(-1)
  assert.deepEqual(reset.positions, initial.positions)
  assert.equal(reset.step, 0)
  await post('session', { scenario: 'galaxy_merger', count: 65, galaxies: 3 })
  await until(() => messages.some((m) => m.type === 'ready' && m.scenario === 'galaxy_merger'))
  const merger = messages.filter((m) => m.type === 'ready').at(-1)
  assert.equal(merger.groups.length, 3)
  assert.equal(merger.positions.length, 195)
  for (const data of [{ scenario: '__proto__', count: 64 }, { scenario: 'star_cluster', count: 10001 }, { scenario: 'galaxy_merger', count: 3, galaxies: 4 }]) {
    const response = await fetch(`${base}/api/session`, { method: 'POST', body: JSON.stringify(data) })
    assert.equal(response.status, 400)
  }
  const rejected = await fetch(`${base}/api/play`, { method: 'POST', headers: { Origin: 'https://example.com' } })
  assert.equal(rejected.status, 403)
  await post('play')
  await until(() => messages.some((m) => m.type === 'state' && m.session === merger.session))
  events.close(); await wait(150)
  const reconnected = []
  events = new EventSource(`${base}/api/events`)
  events.onmessage = (event) => reconnected.push(JSON.parse(event.data))
  await until(() => reconnected.some((m) => m.type === 'status'))
  assert.equal(reconnected.find((m) => m.type === 'status').playing, false)
  assert.ok(reconnected.some((m) => m.type === 'ready' && m.session === merger.session))
  console.log('PASS: real C++ live protocol, real relay/SSE connection, play/pause, speed, deterministic restart, scenario changes, validation and pause on disconnect.')
} finally { events?.close(); await relay.close() }
