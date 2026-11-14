import { Component } from 'react'
import type { ErrorInfo, ReactNode } from 'react'

interface Props {
  children: ReactNode
  title?: string
  message?: string
}

/** Show a recoverable message even when UI outside the canvas fails. */
export class ErrorBoundary extends Component<Props, { failed: boolean }> {
  state = { failed: false }
  static getDerivedStateFromError() { return { failed: true } }
  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error('N-body rendering failed', error, info.componentStack)
  }
  render() {
    if (!this.state.failed) return this.props.children
    return <div className="scene-fallback" role="alert">
      <h2>{this.props.title ?? 'The interface could not be displayed.'}</h2>
      <p>{this.props.message ?? 'An error interrupted the display. Reload the page to try again.'}</p>
      <button onClick={() => window.location.reload()}>Reload</button>
    </div>
  }
}
