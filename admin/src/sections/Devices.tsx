import type { AdminStats } from '../types'
import { CardGrid } from '../components/CardGrid'
import { StatCard } from '../components/StatCard'
import { ChartBox } from '../components/ChartBox'
import { PrivacyModeChart } from '../charts/PrivacyModeChart'
import { fmtNum } from '../utils'

export function Devices({ stats }: { stats: AdminStats }) {
  return (
    <div className="section">
      <h2>Devices</h2>
      <CardGrid>
        <StatCard label="Total Devices" value={fmtNum(stats.totalDevices)} />
        <StatCard label="Online" value={fmtNum(stats.onlineDevices)} colorClass="green" />
        <StatCard label="E2EE Enabled" value={fmtNum(stats.e2eeDevices)} colorClass="accent" />
        <StatCard
          label="Stale (30d+)"
          value={fmtNum(stats.staleDevices)}
          colorClass={stats.staleDevices > 0 ? 'yellow' : undefined}
        />
      </CardGrid>
      <div className="chart-row">
        <ChartBox title="Privacy Modes">
          <PrivacyModeChart modes={stats.byPrivacyMode} />
        </ChartBox>
      </div>
    </div>
  )
}
