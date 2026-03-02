export const colors = {
  bg: '#0a0a1a',
  card: '#1a1a2e',
  cardHover: '#222240',
  border: '#2a2a4e',
  text: '#e0e0f0',
  textDim: '#8888aa',
  accent: '#4a9eff',
  accent2: '#7c5cfc',
  green: '#22c55e',
  red: '#ef4444',
  yellow: '#eab308',
  orange: '#f97316',
  inputBg: '#12122a',
} as const

export const tierColors: Record<string, string> = {
  free: '#8888aa',
  pro: '#4a9eff',
  contributor: '#7c5cfc',
}

export const statusColors: Record<string, string> = {
  running: '#4a9eff',
  completed: '#22c55e',
  idle: '#eab308',
  error: '#ef4444',
  pending: '#eab308',
  failed: '#ef4444',
  cancelled: '#8888aa',
}

export const privacyModeColors: Record<string, string> = {
  telemetry_only: '#4a9eff',
  relay_only: '#eab308',
  encrypted: '#22c55e',
}

export const chartDefaults = {
  color: '#8888aa',
  borderColor: '#2a2a4e',
  fontFamily: "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif",
  fontSize: 11,
  legendBoxWidth: 12,
} as const
