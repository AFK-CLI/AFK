import type { AdminStats, TimeseriesPoint } from '../types'
import { CardGrid } from '../components/CardGrid'
import { StatCard } from '../components/StatCard'
import { ChartBox } from '../components/ChartBox'
import { CommandChart } from '../charts/CommandChart'
import { CommandStatusChart } from '../charts/CommandStatusChart'
import { fmtNum } from '../utils'

interface Props {
  stats: AdminStats
  commandPoints: TimeseriesPoint[]
}

export function Commands({ stats, commandPoints }: Props) {
  const c = stats.commandsByStatus ?? {}

  return (
    <div className="section">
      <h2>Commands</h2>
      <CardGrid>
        <StatCard label="Submitted" value={fmtNum(c.pending ?? 0)} />
        <StatCard label="Completed" value={fmtNum(c.completed ?? 0)} colorClass="green" />
        <StatCard
          label="Failed"
          value={fmtNum(c.failed ?? 0)}
          colorClass={(c.failed ?? 0) > 0 ? 'red' : undefined}
        />
        <StatCard label="Cancelled" value={fmtNum(c.cancelled ?? 0)} />
      </CardGrid>
      <div className="chart-row">
        <ChartBox title="Commands per Day (30d)">
          <CommandChart points={commandPoints} />
        </ChartBox>
        <ChartBox title="Command Status">
          <CommandStatusChart statuses={stats.commandsByStatus} />
        </ChartBox>
      </div>
    </div>
  )
}
