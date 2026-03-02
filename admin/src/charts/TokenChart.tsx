import { Line } from 'react-chartjs-2'
import type { TokenTimeseriesPoint } from '../types'
import { colors } from '../theme'
import { shortDate } from '../utils'

export function TokenChart({ points }: { points: TokenTimeseriesPoint[] }) {
  return (
    <Line
      data={{
        labels: points.map((p) => shortDate(p.date)),
        datasets: [
          {
            label: 'Tokens In',
            data: points.map((p) => p.tokensIn),
            borderColor: colors.accent,
            backgroundColor: colors.accent + '20',
            fill: true,
            tension: 0.3,
            pointRadius: 2,
            borderWidth: 2,
          },
          {
            label: 'Tokens Out',
            data: points.map((p) => p.tokensOut),
            borderColor: colors.accent2,
            backgroundColor: colors.accent2 + '20',
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
        plugins: { legend: { display: true } },
        scales: { y: { beginAtZero: true } },
      }}
    />
  )
}
