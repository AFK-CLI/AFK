import { Line } from 'react-chartjs-2'
import type { TimeseriesPoint } from '../types'
import { colors } from '../theme'
import { shortDate } from '../utils'

export function RegistrationChart({ points }: { points: TimeseriesPoint[] }) {
  return (
    <Line
      data={{
        labels: points.map((p) => shortDate(p.date)),
        datasets: [
          {
            label: 'Registrations',
            data: points.map((p) => p.count),
            borderColor: colors.accent,
            backgroundColor: colors.accent + '20',
            fill: true,
            tension: 0.3,
            pointRadius: 2,
            borderWidth: 2,
          },
        ],
      }}
      options={{
        responsive: true,
        maintainAspectRatio: false,
        plugins: { legend: { display: false } },
        scales: { y: { beginAtZero: true, ticks: { precision: 0 } } },
      }}
    />
  )
}
