interface StatCardProps {
  label: string
  value: string
  colorClass?: string
}

export function StatCard({ label, value, colorClass }: StatCardProps) {
  return (
    <div className="card">
      <div className="label">{label}</div>
      <div className={`value ${colorClass ?? ''}`}>{value}</div>
    </div>
  )
}
