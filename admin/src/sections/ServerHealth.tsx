import type { RuntimeMetrics } from '../types'
import { CardGrid } from '../components/CardGrid'
import { StatCard } from '../components/StatCard'
import { fmtNum, fmtUptime } from '../utils'

interface Props {
  runtime: RuntimeMetrics
  dbSizeBytes: number
}

export function ServerHealth({ runtime, dbSizeBytes }: Props) {
  const r = runtime
  const dbMB = dbSizeBytes ? (dbSizeBytes / (1024 * 1024)).toFixed(1) + ' MB' : 'N/A'

  return (
    <div className="section">
      <h2>Server Health</h2>
      <CardGrid>
        <StatCard label="Uptime" value={fmtUptime(r.uptime)} colorClass="green" />
        <StatCard label="DB Size" value={dbMB} />
        <StatCard label="WS Agents" value={fmtNum(r.agentConnections)} colorClass="accent" />
        <StatCard label="WS iOS" value={fmtNum(r.iosConnections)} colorClass="accent" />
        <StatCard label="Total Requests" value={fmtNum(r.requestsTotal)} />
        <StatCard
          label="Request Errors"
          value={fmtNum(r.requestErrors)}
          colorClass={r.requestErrors > 0 ? 'red' : undefined}
        />
        <StatCard label="WS Received" value={fmtNum(r.wsMessagesReceived)} />
        <StatCard label="WS Sent" value={fmtNum(r.wsMessagesSent)} />
        <StatCard
          label="WS Dropped"
          value={fmtNum(r.wsDroppedMessages)}
          colorClass={r.wsDroppedMessages > 0 ? 'yellow' : undefined}
        />
        <StatCard
          label="Rate Limit Hits"
          value={fmtNum(r.rateLimitHits)}
          colorClass={r.rateLimitHits > 0 ? 'yellow' : undefined}
        />
      </CardGrid>
    </div>
  )
}
