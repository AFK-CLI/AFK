import type { AdminStats, TimeseriesPoint, TokenTimeseriesPoint, AdminProject } from '../types'
import { CardGrid } from '../components/CardGrid'
import { StatCard } from '../components/StatCard'
import { ChartBox } from '../components/ChartBox'
import { SessionChart } from '../charts/SessionChart'
import { SessionStatusChart } from '../charts/SessionStatusChart'
import { TokenChart } from '../charts/TokenChart'
import { fmtNum, fmtDuration, fmtTokens } from '../utils'

interface Props {
  stats: AdminStats
  sessionPoints: TimeseriesPoint[]
  tokenPoints: TokenTimeseriesPoint[]
  projects: AdminProject[]
}

export function Sessions({ stats, sessionPoints, tokenPoints, projects }: Props) {
  return (
    <div className="section">
      <h2>Sessions</h2>
      <CardGrid>
        <StatCard label="Total Sessions" value={fmtNum(stats.totalSessions)} />
        <StatCard label="Avg Duration" value={fmtDuration(stats.avgDuration)} />
        <StatCard label="Avg Turns" value={stats.avgTurnCount ? stats.avgTurnCount.toFixed(1) : '0'} />
        <StatCard label="Tokens In" value={fmtTokens(stats.totalTokensIn)} />
        <StatCard label="Tokens Out" value={fmtTokens(stats.totalTokensOut)} />
      </CardGrid>
      <div className="chart-row">
        <ChartBox title="Sessions per Day (30d)">
          <SessionChart points={sessionPoints} />
        </ChartBox>
        <ChartBox title="Session Status">
          <SessionStatusChart statuses={stats.sessionsByStatus} />
        </ChartBox>
      </div>
      <div className="chart-row">
        <ChartBox title="Token Usage (30d)">
          <TokenChart points={tokenPoints} />
        </ChartBox>
        <ChartBox title="Top Projects">
          <table>
            <thead>
              <tr>
                <th>Project</th>
                <th>Sessions</th>
              </tr>
            </thead>
            <tbody>
              {projects.length === 0 ? (
                <tr>
                  <td colSpan={2} style={{ color: 'var(--text-dim)' }}>
                    No projects yet
                  </td>
                </tr>
              ) : (
                projects.map((p) => (
                  <tr key={p.id}>
                    <td>{p.name || p.path || p.id}</td>
                    <td>{p.sessionCount}</td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </ChartBox>
      </div>
    </div>
  )
}
