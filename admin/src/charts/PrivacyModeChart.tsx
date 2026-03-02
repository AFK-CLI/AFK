import { Bar } from 'react-chartjs-2'
import { privacyModeColors } from '../theme'

export function PrivacyModeChart({ modes }: { modes: Record<string, number> }) {
  const labels = Object.keys(modes)
  const data = Object.values(modes)
  const bg = labels.map((l) => privacyModeColors[l] ?? '#666')

  return (
    <Bar
      data={{
        labels,
        datasets: [{ label: 'Devices', data, backgroundColor: bg, borderRadius: 4 }],
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
