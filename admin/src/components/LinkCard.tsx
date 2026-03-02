import { useNavigate } from 'react-router-dom'

interface Props {
  label: string
  value: string
  to: string
  colorClass?: string
}

export function LinkCard({ label, value, to, colorClass }: Props) {
  const nav = useNavigate()
  return (
    <div className="card link-card" onClick={() => nav(to)}>
      <div className="label">{label}</div>
      <div className={`value ${colorClass ?? ''}`}>{value}</div>
    </div>
  )
}
