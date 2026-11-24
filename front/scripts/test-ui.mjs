// Tests for the main browser interactions.
import assert from 'node:assert/strict'
import { JSDOM } from 'jsdom'
import { EventSource } from 'undici'
import { createServer } from 'vite'
import { createLiveServer } from '../bridge/server.mjs'
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms))
async function until(predicate) {
  const end = Date.now() + 5000
  while (!predicate()) { assert.ok(Date.now() < end, 'Timed out waiting for the CPU'); await wait(10) }
}
const relay = createLiveServer({ port: 0 })
const address = await relay.listen()
const base = `http://127.0.0.1:${address.port}`
const dom = new JSDOM('<!doctype html><div id="root"></div>', { url: base })
globalThis.window = dom.window; globalThis.document = dom.window.document
globalThis.IS_REACT_ACT_ENVIRONMENT = true
const originalFetch = globalThis.fetch
const originalEventSource = globalThis.EventSource
const originalConsoleError = console.error
const errors = []
console.error = (...args) => errors.push(args.map(String).join(' '))
globalThis.fetch = (input, options) => originalFetch(typeof input === 'string' && input.startsWith('/') ? base + input : input, options)
globalThis.EventSource = class extends EventSource { constructor(path) { super(new URL(path, base)) } }
const { createElement, act, StrictMode } = await import('react')
const { createRoot } = await import('react-dom/client')
const vite = await createServer({ root: new URL('..', import.meta.url).pathname, server: { middlewareMode: true }, appType: 'custom' })
const root = createRoot(document.getElementById('root'))
let disconnect
try {
  const { BodyNavigator } = await vite.ssrLoadModule('/src/components/BodyNavigator.tsx')
  const { SimulationControls } = await vite.ssrLoadModule('/src/components/SimulationControls.tsx')
  const { useSimulationStore: store } = await vite.ssrLoadModule('/src/store/simulationStore.ts')
  await act(async () => root.render(createElement(StrictMode, null, createElement(BodyNavigator))))
  assert.equal(document.querySelectorAll('button').length, 10)
  await act(async () => {
    disconnect = store.getState().connect()
    await store.getState().loadScenario('solar_system')
    await until(() => store.getState().metadata?.count === 9 && !store.getState().isLoading)
    await wait(40)
  })
  assert.equal(errors.length, 0, errors.join(' | '))
  await act(async () => {
    await store.getState().loadScenario('galaxy_merger', 64, 3)
    await until(() => store.getState().metadata?.count === 64)
    await wait(30)
  })
  assert.equal(document.querySelectorAll('button').length, 4)
  const galaxy = [...document.querySelectorAll('button')].find((button) => button.textContent.includes('Galaxy C'))
  await act(async () => galaxy.dispatchEvent(new dom.window.MouseEvent('click', { bubbles: true })))
  assert.equal(galaxy.getAttribute('aria-pressed'), 'true')
  await act(async () => root.render(createElement(SimulationControls)))
  assert.equal(document.querySelector('[aria-label="Open settings"]'), null)
  assert.equal(document.querySelector('input[type="file"]'), null)
  assert.equal(document.querySelector('input[type="range"]'), null)
  await act(async () => {
    await store.getState().togglePlaying()
    await until(() => store.getState().time > 0)
    await store.getState().togglePlaying()
    await wait(120)
  })
  const previous = store.getState().time
  await act(async () => { await wait(100) })
  assert.equal(store.getState().time, previous)
  const revision = store.getState().revision
  await act(async () => {
    await store.getState().reset()
    await until(() => store.getState().revision > revision)
    await wait(40)
  })
  assert.equal(store.getState().time, 0)
  assert.equal(errors.length, 0, errors.join(' | '))
  disconnect(); disconnect = null
  const { ErrorBoundary } = await vite.ssrLoadModule('/src/components/ErrorBoundary.tsx')
  function BrokenView() { throw new Error('Intentional UI failure') }
  await act(async () => root.render(createElement(ErrorBoundary, null, createElement(BrokenView))))
  assert.ok(document.querySelector('[role="alert"]')?.textContent.includes('The interface could not be displayed.'))
  console.log('PASS: React startup, real CPU live updates, group navigation, pause/restart, no settings/import/history controls, and recoverable UI failure.')
} finally {
  disconnect?.()
  await act(async () => root.unmount())
  await relay.close(); await vite.close()
  console.error = originalConsoleError; globalThis.fetch = originalFetch; globalThis.EventSource = originalEventSource
  dom.window.close()
  delete globalThis.window; delete globalThis.document; delete globalThis.IS_REACT_ACT_ENVIRONMENT
}
