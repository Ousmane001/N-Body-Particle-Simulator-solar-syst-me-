// Local startup for the CPU engine, relay, and frontend.
import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { createServer } from 'vite'
import { createLiveServer } from '../bridge/server.mjs'

const engine = fileURLToPath(new URL('../../Engine', import.meta.url))
const build = fileURLToPath(new URL('../../build', import.meta.url))
execFileSync('cmake', ['-S', engine, '-B', build], { stdio: 'inherit' })
execFileSync('cmake', ['--build', build, '--config', 'Release', '--target', 'nbody_cpu'], { stdio: 'inherit' })
const relay = createLiveServer()
let vite
try {
  await relay.listen()
  vite = await createServer({ root: fileURLToPath(new URL('../', import.meta.url)) })
  await vite.listen()
  vite.printUrls()
} catch (error) {
  await relay.close()
  console.error(error.message)
  process.exit(1)
}
let closing = false
async function close() {
  if (closing) return
  closing = true
  await Promise.all([relay.close(), vite.close()])
  process.exit(0)
}
process.on('SIGINT', close)
process.on('SIGTERM', close)
