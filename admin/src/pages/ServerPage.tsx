import { useState, useEffect } from 'react'
import type { AdminProject } from '../types'
import { api } from '../api'
import { useAuth } from '../contexts/AuthContext'
import { PageHeader } from '../components/PageHeader'
import { CardGrid } from '../components/CardGrid'
import { StatCard } from '../components/StatCard'
import { DataTable } from '../components/DataTable'
import { fmtNum, fmtUptime } from '../utils'

export function ServerPage() {
  const { dashboard: dash, refreshDashboard: refresh } = useAuth()
  const [projects, setProjects] = useState<AdminProject[]>([])

  useEffect(() => {
    api<{ projects: AdminProject[] }>('/v1/admin/top-projects?limit=10')
      .then((p) => setProjects(p.projects ?? []))
      .catch(() => {})
  }, [])

  if (!dash) {
    return <div style={{ color: 'var(--text-dim)', padding: 40 }}>Loading...</div>
  }

  const r = dash.runtime
  const dbMB = dash.dbSizeBytes ? (dash.dbSizeBytes / (1024 * 1024)).toFixed(1) + ' MB' : 'N/A'

  return (
    <div>
      <PageHeader
        title="Server"
        subtitle="Runtime health and performance"
        actions={
          <button className="btn-sm" onClick={refresh}>
            Refresh
          </button>
        }
      />
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

      <div className="section">
        <h2>Top Projects</h2>
        <div className="table-wrap">
          <DataTable
            columns={[
              { header: 'Project', render: (p: AdminProject) => p.name || p.path || p.id },
              { header: 'Sessions', render: (p: AdminProject) => p.sessionCount },
            ]}
            data={projects}
            emptyText="No projects yet"
          />
        </div>
      </div>
    </div>
  )
}
