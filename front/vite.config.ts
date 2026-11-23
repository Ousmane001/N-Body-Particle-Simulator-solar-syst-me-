// Configure Vite and the local proxy to the live relay.
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
const proxy = { '/api': { target: 'http://127.0.0.1:8787', changeOrigin: false, timeout: 0, proxyTimeout: 0 } }
export default defineConfig({
  plugins: [react()],
  server: { host: '127.0.0.1', port: 5173, strictPort: true, proxy },
  preview: { host: '127.0.0.1', proxy },
})
