// Start the CPU engine and relay its live state to the browser.
import { createServer } from 'node:http'
import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'
import { fileURLToPath } from 'node:url'

const executable = fileURLToPath(new URL('../../build/release/nbody_cpu', import.meta.url))
const scenarios = { solar_system: 'solar', star_cluster: 'cluster', disk_galaxy: 'galaxy', galaxy_merger: 'merger' }
const speeds = [0.25, 0.5, 1, 2, 4]

/** The relay only starts the executable, requests work and forwards messages.
 * All gravity and integration stay in the independent C++ process. */
export function createLiveServer({ binary = executable, port = 8787 } = {}) {
  const clients = new Set()
  let child = null, timer = null, session = 0
  let playing = false, loading = false, busy = false, speed = 1
  let lastReady = null, lastState = null, lastError = null
  let options = { scenario: 'solar_system', count: 9, galaxies: 2 }
  let requestedSteps = 1, requestStarted = 0, secondsPerStep = 0
  let stderr = ''

  function send(response, message) {
    // Slow browsers reconnect to the current state instead of building a queue.
    if (response.writableLength > 2 * 1024 * 1024) { response.destroy(); return }
    response.write(`data: ${JSON.stringify(message)}\n\n`)
  }
  function publish(message) { for (const response of clients) send(response, message) }
  function status() { return { type: 'status', session, playing, loading, speed } }
  function clearTimer() { if (timer !== null) clearTimeout(timer); timer = null }
  function stopChild() {
    clearTimer()
    const previous = child; child = null
    if (previous) { previous.stdin.destroy(); previous.kill('SIGTERM') }
    playing = false; loading = false; busy = false
  }
  function fail(message) {
    stopChild(); lastError = { type: 'error', session, message }
    publish(lastError); publish(status())
  }
  function requestWork() {
    clearTimer()
    if (!child || !lastReady || !playing || loading || busy) return
    // Prefer short batches for responsive Pause. The fixed physical dt never changes.
    const desired = Math.max(1, Math.round(10 * speed))
    const budget = secondsPerStep > 0 ? Math.max(1, Math.floor(0.025 / secondsPerStep)) : 1
    requestedSteps = Math.min(desired, budget)
    busy = true; requestStarted = performance.now()
    child.stdin.write(`step ${requestedSteps}\n`)
  }
  function launch(next) {
    stopChild(); session++; options = next
    lastReady = null; lastState = null; lastError = null; stderr = ''; secondsPerStep = 0
    loading = true; publish(status())
    const process = spawn(binary, ['--scenario', scenarios[next.scenario], '--count', String(next.count), '--galaxies', String(next.galaxies)], { stdio: ['pipe', 'pipe', 'pipe'] })
    child = process
    process.on('error', (error) => { if (child === process) fail(`Could not start the CPU engine: ${error.message}`) })
    process.stdin.on('error', (error) => { if (child === process) fail(`CPU connection failed: ${error.message}`) })
    process.stderr.on('data', (chunk) => { if (child === process) stderr = (stderr + chunk.toString()).slice(-2000) })
    const lines = createInterface({ input: process.stdout })
    lines.on('line', (line) => {
      if (child !== process) return
      try {
        const message = { ...JSON.parse(line), session }
        if (message.type === 'ready') {
          lastReady = message; loading = false
          publish(message); publish(status())
        } else if (message.type === 'state') {
          lastState = message; busy = false
          secondsPerStep = message.computeSeconds / requestedSteps
          publish(message)
          if (playing) timer = setTimeout(requestWork, Math.max(0, 50 - (performance.now() - requestStarted)))
        } else throw new Error('Unknown CPU message.')
      } catch (error) { fail(`Invalid CPU response: ${error.message}`) }
    })
    process.on('exit', (code, signal) => {
      lines.close()
      if (child === process) fail(stderr.trim() || `CPU engine stopped (${signal ?? code}).`)
    })
  }
  function validateSession(data) {
    if (!data || !Object.hasOwn(scenarios, data.scenario)) throw new Error('Choose a supported scenario.')
    const count = data.scenario === 'solar_system' ? 9 : data.count
    if (!Number.isInteger(count) || count < 2 || count > 10000) throw new Error('Choose between 2 and 10,000 bodies for live CPU use.')
    const galaxies = data.galaxies ?? 2
    if (!Number.isInteger(galaxies) || galaxies < 2 || galaxies > 4) throw new Error('Choose between two and four galaxies.')
    if (data.scenario === 'galaxy_merger' && count < galaxies * 2) throw new Error('Each galaxy needs at least two bodies.')
    return { scenario: data.scenario, count, galaxies }
  }
  async function readBody(request) {
    let text = ''
    for await (const chunk of request) {
      text += chunk.toString()
      if (text.length > 4096) throw new Error('Request is too large.')
    }
    try { return text ? JSON.parse(text) : {} } catch { throw new Error('Invalid JSON request.') }
  }
  function reply(response, code, data) {
    response.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' })
    response.end(JSON.stringify(data))
  }
  const server = createServer(async (request, response) => {
    const path = request.url?.split('?')[0]
    if (request.headers.origin && !['http://127.0.0.1:5173', 'http://localhost:5173', 'http://127.0.0.1:4173', 'http://localhost:4173'].includes(request.headers.origin)) {
      reply(response, 403, { error: 'Origin not allowed.' }); return
    }
    if (request.method === 'GET' && path === '/api/events') {
      response.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache, no-transform', Connection: 'keep-alive', 'X-Accel-Buffering': 'no' })
      response.flushHeaders()
      clients.add(response)
      if (lastReady) send(response, lastReady)
      if (lastState) send(response, lastState)
      if (lastError) send(response, lastError)
      send(response, status())
      response.on('close', () => {
        clients.delete(response)
        if (clients.size === 0) { playing = false; clearTimer() }
      })
      return
    }
    if (request.method === 'GET' && path === '/api/health') { reply(response, 200, { backend: 'cpu-sequential' }); return }
    if (request.method !== 'POST') { reply(response, 404, { error: 'Not found.' }); return }
    try {
      const data = await readBody(request)
      if (path === '/api/session') launch(validateSession(data))
      else if (path === '/api/reset') launch(options)
      else if (path === '/api/play') {
        if (!child || loading || !lastReady) throw new Error('The CPU engine is not ready.')
        playing = true; publish(status()); requestWork()
      } else if (path === '/api/pause') { playing = false; clearTimer(); publish(status()) }
      else if (path === '/api/speed') {
        if (!speeds.includes(data.speed)) throw new Error('Unsupported speed.')
        speed = data.speed; publish(status())
      } else { reply(response, 404, { error: 'Not found.' }); return }
      reply(response, 200, status())
    } catch (error) { reply(response, 400, { error: error.message }) }
  })
  return {
    server,
    async listen() { await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve) }); return server.address() },
    async close() { stopChild(); for (const response of clients) response.end(); clients.clear(); await new Promise((resolve) => server.close(resolve)); server.closeAllConnections() },
  }
}
