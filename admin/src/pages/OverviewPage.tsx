import { useState, useEffect, useCallback } from 'react'
import type { TimeseriesPoint } from '../types'
import { api } from '../api'
import { useAuth } from '../contexts/AuthContext'
import { PageHeader } from '../components/PageHeader'
import { LinkCard } from '../components/LinkCard'
import { CardGrid } from '../components/CardGrid'
import { ChartBox } from '../components/ChartBox'
import { RegistrationChart } from '../charts/RegistrationChart'
import { SessionChart } from '../charts/SessionChart'
import { fmtNum, fmtTokens } from '../utils'

export function OverviewPage() {
  const { dashboard: dash } = useAuth()
  const [regPoints, setRegPoints] = useState<TimeseriesPoint[]>([])
  const [sessPoints, setSessPoints] = useState<TimeseriesPoint[]>([])

  const loadTimeseries = useCallback(async () => {
    try {
      const [regTS, sessTS] = await Promise.all([
        api<{ points: TimeseriesPoint[] }>('/v1/admin/timeseries?metric=registrations&days=30'),
        api<{ points: TimeseriesPoint[] }>('/v1/admin/timeseries?metric=sessions&days=30'),
      ])
      setRegPoints(regTS.points ?? [])
      setSessPoints(sessTS.points ?? [])
    } catch {
      // ignore
    }
  }, [])

  useEffect(() => {
    loadTimeseries()
  }, [loadTimeseries])

  if (!dash) {
    return (
      <div style={{ textAlign: 'center', paddingTop: 100, color: 'var(--text-dim)' }}>
        Loading...
      </div>
    )
  }

  const s = dash.stats
  const r = dash.runtime
  const totalCommands = Object.values(s.commandsByStatus ?? {}).reduce((a, b) => a + b, 0)

  return (
    <div>
      <PageHeader title="Overview" subtitle="Key metrics at a glance" />
      <CardGrid>
        <LinkCard label="Total Users" value={fmtNum(s.totalUsers)} to="/users" />
        <LinkCard label="Active Today" value={fmtNum(s.dau)} to="/users" colorClass="green" />
        <LinkCard label="Devices" value={fmtNum(s.totalDevices)} to="/devices" />
        <LinkCard
          label="Online"
          value={fmtNum(s.onlineDevices)}
          to="/devices"
          colorClass="green"
        />
        <LinkCard label="Sessions" value={fmtNum(s.totalSessions)} to="/sessions" />
        <LinkCard label="Commands" value={fmtNum(totalCommands)} to="/commands" />
        <LinkCard
          label="Tokens"
          value={fmtTokens(s.totalTokensIn + s.totalTokensOut)}
          to="/sessions"
          colorClass="accent"
        />
        <LinkCard
          label="WS Connections"
          value={fmtNum(r.agentConnections + r.iosConnections)}
          to="/server"
          colorClass="accent"
        />
      </CardGrid>
      <div className="chart-row">
        <ChartBox title="Registrations (30d)">
          <RegistrationChart points={regPoints} />
        </ChartBox>
        <ChartBox title="Sessions per Day (30d)">
          <SessionChart points={sessPoints} />
        </ChartBox>
      </div>
    </div>
  )
}
