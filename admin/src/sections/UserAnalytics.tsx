import type { AdminStats, TimeseriesPoint } from '../types'
import { CardGrid } from '../components/CardGrid'
import { StatCard } from '../components/StatCard'
import { ChartBox } from '../components/ChartBox'
import { RegistrationChart } from '../charts/RegistrationChart'
import { TierChart } from '../charts/TierChart'
import { fmtNum } from '../utils'

interface Props {
  stats: AdminStats
  registrationPoints: TimeseriesPoint[]
}

export function UserAnalytics({ stats, registrationPoints }: Props) {
  return (
    <div className="section">
      <h2>User Analytics</h2>
      <CardGrid>
        <StatCard label="Total Users" value={fmtNum(stats.totalUsers)} />
        <StatCard label="Today" value={fmtNum(stats.registeredToday)} colorClass="green" />
        <StatCard label="This Week" value={fmtNum(stats.registeredThisWeek)} />
        <StatCard label="DAU" value={fmtNum(stats.dau)} colorClass="accent" />
        <StatCard label="WAU" value={fmtNum(stats.wau)} />
        <StatCard label="MAU" value={fmtNum(stats.mau)} />
      </CardGrid>
      <div className="chart-row">
        <ChartBox title="Registrations (30d)">
          <RegistrationChart points={registrationPoints} />
        </ChartBox>
        <ChartBox title="Users by Tier">
          <TierChart tiers={stats.usersByTier} />
        </ChartBox>
      </div>
    </div>
  )
}
