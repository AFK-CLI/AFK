export function fmtNum(n: number | undefined | null): string {
  if (n === undefined || n === null) return '0'
  return n.toLocaleString()
}

export function fmtDuration(secs: number | undefined | null): string {
  if (!secs || secs < 0) return '0s'
  if (secs < 60) return Math.round(secs) + 's'
  if (secs < 3600) return Math.round(secs / 60) + 'm'
  return (secs / 3600).toFixed(1) + 'h'
}

export function fmtUptime(secs: number): string {
  const d = Math.floor(secs / 86400)
  const h = Math.floor((secs % 86400) / 3600)
  const m = Math.floor((secs % 3600) / 60)
  if (d > 0) return d + 'd ' + h + 'h'
  if (h > 0) return h + 'h ' + m + 'm'
  return m + 'm'
}

export function fmtTokens(n: number | undefined | null): string {
  if (!n) return '0'
  if (n >= 1e9) return (n / 1e9).toFixed(1) + 'B'
  if (n >= 1e6) return (n / 1e6).toFixed(1) + 'M'
  if (n >= 1e3) return (n / 1e3).toFixed(1) + 'K'
  return n.toString()
}

export function fmtDate(s: string | undefined | null): string {
  if (!s) return ''
  const d = new Date(s)
  return (
    d.toLocaleDateString() +
    ' ' +
    d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
  )
}

export function shortDate(s: string): string {
  if (!s) return ''
  return s.substring(5) // MM-DD from YYYY-MM-DD
}
