import type { AdminStats } from '../types'
import { CardGrid } from '../components/CardGrid'
import { StatCard } from '../components/StatCard'
import { fmtNum } from '../utils'

export function PushNotifications({ stats }: { stats: AdminStats }) {
  const pp = stats.pushByPlatform ?? {}

  return (
    <div className="section">
      <h2>Push Notifications</h2>
      <CardGrid>
        <StatCard label="Total Tokens" value={fmtNum(stats.totalPushTokens)} />
        {Object.entries(pp).map(([platform, count]) => (
          <StatCard
            key={platform}
            label={platform.charAt(0).toUpperCase() + platform.slice(1)}
            value={fmtNum(count)}
          />
        ))}
      </CardGrid>
    </div>
  )
}
