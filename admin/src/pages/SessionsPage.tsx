import { useState, useEffect, useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import type {
  AdminSession,
  TimeseriesPoint,
  TokenTimeseriesPoint,
  AdminProject,
} from '../types'
import { api, apiPut } from '../api'
import { useAuth } from '../contexts/AuthContext'
import { PageHeader } from '../components/PageHeader'
import { CardGrid } from '../components/CardGrid'
import { StatCard } from '../components/StatCard'
import { ChartBox } from '../components/ChartBox'
import { DataTable } from '../components/DataTable'
import { Pagination } from '../components/Pagination'
import { Badge } from '../components/Badge'
import { ActionButton } from '../components/ActionButton'
import { ConfirmDialog } from '../components/ConfirmDialog'
import { SessionChart } from '../charts/SessionChart'
import { SessionStatusChart } from '../charts/SessionStatusChart'
import { TokenChart } from '../charts/TokenChart'
import { useToast } from '../contexts/ToastContext'
import { usePagination } from '../hooks/usePagination'
import { fmtNum, fmtDuration, fmtTokens, fmtDate } from '../utils'

export function SessionsPage() {
  const nav = useNavigate()
  const { showToast } = useToast()
  const { dashboard: dashData } = useAuth()
  const [sessions, setSessions] = useState<AdminSession[]>([])
  const [statusFilter, setStatusFilter] = useState('')
  const [sessPoints, setSessPoints] = useState<TimeseriesPoint[]>([])
  const [tokPoints, setTokPoints] = useState<TokenTimeseriesPoint[]>([])
  const [projects, setProjects] = useState<AdminProject[]>([])
  const pag = usePagination()
  const [endTarget, setEndTarget] = useState<AdminSession | null>(null)
  const [actionLoading, setActionLoading] = useState(false)

  const load = useCallback(async () => {
    try {
      const data = await api<{ sessions: AdminSession[]; total: number }>(
        `/v1/admin/sessions?status=${encodeURIComponent(statusFilter)}&limit=${pag.pageSize}&offset=${pag.offset}`,
      )
      setSessions(data.sessions ?? [])
      pag.setTotal(data.total)
    } catch {
      // handled
    }
  }, [statusFilter, pag.offset, pag.pageSize, pag.setTotal])

  useEffect(() => {
    load()
  }, [load])

  useEffect(() => {
    Promise.all([
      api<{ points: TimeseriesPoint[] }>('/v1/admin/timeseries?metric=sessions&days=30'),
      api<{ points: TokenTimeseriesPoint[] }>('/v1/admin/timeseries?metric=tokens&days=30'),
      api<{ projects: AdminProject[] }>('/v1/admin/top-projects?limit=10'),
    ]).then(([sp, tp, pr]) => {
      setSessPoints(sp.points ?? [])
      setTokPoints(tp.points ?? [])
      setProjects(pr.projects ?? [])
    }).catch(() => {})
  }, [])

  const doForceEnd = async () => {
    if (!endTarget) return
    setActionLoading(true)
    try {
      await apiPut(`/v1/admin/sessions/${endTarget.id}/status`, { status: 'completed' })
      showToast('Session force-ended')
      setEndTarget(null)
      load()
    } catch (e) {
      showToast(e instanceof Error ? e.message : 'Failed', 'error')
    } finally {
      setActionLoading(false)
    }
  }

  const s = dashData?.stats

  const statusBadge = (status: string) => {
    const v =
      status === 'completed'
        ? 'green'
        : status === 'running'
          ? 'blue'
          : status === 'error'
            ? 'red'
            : 'yellow'
    return <Badge text={status} variant={v as 'green' | 'blue' | 'red' | 'yellow'} />
  }

  return (
    <div>
      <PageHeader title="Sessions" subtitle="Monitor and manage sessions" />
      {s && (
        <CardGrid>
          <StatCard label="Total Sessions" value={fmtNum(s.totalSessions)} />
          <StatCard label="Avg Duration" value={fmtDuration(s.avgDuration)} />
          <StatCard
            label="Avg Turns"
            value={s.avgTurnCount ? s.avgTurnCount.toFixed(1) : '0'}
          />
          <StatCard label="Tokens In" value={fmtTokens(s.totalTokensIn)} />
          <StatCard label="Tokens Out" value={fmtTokens(s.totalTokensOut)} />
        </CardGrid>
      )}
      {s && (
        <>
          <div className="chart-row">
            <ChartBox title="Sessions per Day (30d)">
              <SessionChart points={sessPoints} />
            </ChartBox>
            <ChartBox title="Session Status">
              <SessionStatusChart statuses={s.sessionsByStatus} />
            </ChartBox>
          </div>
          <div className="chart-row">
            <ChartBox title="Token Usage (30d)">
              <TokenChart points={tokPoints} />
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
                        <td>{p.name || p.id}</td>
                        <td>{p.sessionCount}</td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </ChartBox>
          </div>
        </>
      )}
      <div className="table-wrap">
        <div className="table-controls">
          <select
            value={statusFilter}
            onChange={(e) => {
              setStatusFilter(e.target.value)
              pag.reset()
            }}
          >
            <option value="">All Statuses</option>
            <option value="running">Running</option>
            <option value="completed">Completed</option>
            <option value="idle">Idle</option>
            <option value="error">Error</option>
          </select>
        </div>
        <DataTable
          columns={[
            {
              header: 'ID',
              render: (s: AdminSession) => (
                <span title={s.id}>{s.id.substring(0, 8)}</span>
              ),
            },
            { header: 'User', render: (s: AdminSession) => s.userEmail },
            { header: 'Status', render: (s: AdminSession) => statusBadge(s.status) },
            { header: 'Project', render: (s: AdminSession) => s.projectName || 'N/A' },
            { header: 'Turns', render: (s: AdminSession) => s.turnCount },
            {
              header: 'Tokens',
              render: (s: AdminSession) => fmtTokens(s.tokensIn + s.tokensOut),
            },
            { header: 'Started', render: (s: AdminSession) => fmtDate(s.startedAt) },
            {
              header: 'Actions',
              render: (s: AdminSession) =>
                s.status === 'running' || s.status === 'idle' ? (
                  <ActionButton
                    label="Force End"
                    variant="danger"
                    onClick={() => setEndTarget(s)}
                  />
                ) : null,
            },
          ]}
          data={sessions}
          onRowClick={(s) => nav(`/sessions/${s.id}`)}
          emptyText="No sessions found"
        />
        <Pagination
          start={pag.start}
          end={pag.end}
          total={pag.total}
          hasPrev={pag.hasPrev}
          hasNext={pag.hasNext}
          onPrev={pag.prevPage}
          onNext={pag.nextPage}
        />
      </div>
      <ConfirmDialog
        open={!!endTarget}
        title="Force End Session"
        message={`Force end session ${endTarget?.id.substring(0, 8)}? This will mark it as completed.`}
        confirmLabel="End Session"
        confirmVariant="danger"
        loading={actionLoading}
        onConfirm={doForceEnd}
        onCancel={() => setEndTarget(null)}
      />
    </div>
  )
}
