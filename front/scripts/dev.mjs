import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { createServer } from 'vite'
import { createLiveServer } from '../bridge/server.mjs'

const root = fileURLToPath(new URL('../../', import.meta.url))
const engine = fileURLToPath(new URL('../../moteur', import.meta.url))
const build = fileURLToPath(new URL('../../moteur/build', import.meta.url))
// Build the independent executable, then start the communication relay and UI.
execFileSync('cmake', ['-S', engine, '-B', build, '-DCMAKE_BUILD_TYPE=Release'], { cwd: root, stdio: 'inherit' })
execFileSync('cmake', ['--build', build, '-j', '4'], { cwd: root, stdio: 'inherit' })
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
