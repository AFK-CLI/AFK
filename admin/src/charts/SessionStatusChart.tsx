import { Doughnut } from 'react-chartjs-2'
import { statusColors } from '../theme'

export function SessionStatusChart({ statuses }: { statuses: Record<string, number> }) {
  const labels = Object.keys(statuses)
  const data = Object.values(statuses)
  const bg = labels.map((l) => statusColors[l] ?? '#666')

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
