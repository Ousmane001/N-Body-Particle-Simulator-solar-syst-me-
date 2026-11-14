export function Icon({ name, size = 18 }: { name: string; size?: number }) {
  const paths: Record<string, React.ReactNode> = {
    play: <path d="m8 5 11 7-11 7z" fill="currentColor" stroke="none" />,
    pause: <><path d="M8 5v14M16 5v14" strokeWidth="3" /></>,
    reset: <><path d="M3 11a9 9 0 1 1 2.7 7M3 4v7h7" /></>,
    close: <path d="m6 6 12 12M6 18 18 6" />,
    overview: <><ellipse cx="12" cy="12" rx="10" ry="5" transform="rotate(-30 12 12)" /><circle cx="12" cy="12" r="2" fill="currentColor" /></>,
    solar: <><circle cx="12" cy="12" r="4" /><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5" /></>,
    galaxy: <><ellipse cx="12" cy="12" rx="10" ry="4" transform="rotate(-30 12 12)" /><circle cx="12" cy="12" r="2" /><path d="m7 4-1 3m11 10 1 3" /></>,
    merger: <><ellipse cx="8" cy="9" rx="6" ry="3" transform="rotate(-35 8 9)" /><ellipse cx="16" cy="16" rx="6" ry="3" transform="rotate(25 16 16)" /></>,
    cluster: <><circle cx="12" cy="12" r="2" /><circle cx="6" cy="8" r="1" /><circle cx="17" cy="6" r="1" /><circle cx="19" cy="15" r="1" /><circle cx="9" cy="19" r="1" /><circle cx="4" cy="15" r="1" /><circle cx="13" cy="3" r=".6" /></>,
  }
  return <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{paths[name] ?? paths.overview}</svg>
}
