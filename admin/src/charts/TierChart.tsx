import { Doughnut } from 'react-chartjs-2'
import { tierColors } from '../theme'

export function TierChart({ tiers }: { tiers: Record<string, number> }) {
  const labels = Object.keys(tiers)
  const data = Object.values(tiers)
  const bg = labels.map((l) => tierColors[l] ?? '#666')

  return (
    <Doughnut
      data={{
        labels,
        datasets: [{ data, backgroundColor: bg, borderWidth: 0 }],
      }}
      options={{
        responsive: true,
        maintainAspectRatio: false,
        plugins: { legend: { display: true, position: 'right' } },
      }}
    />
  )
}
