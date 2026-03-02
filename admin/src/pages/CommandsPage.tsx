import { useState, useEffect, useCallback } from 'react'
import type { AdminCommand, TimeseriesPoint } from '../types'
import { api } from '../api'
import { useAuth } from '../contexts/AuthContext'
import { PageHeader } from '../components/PageHeader'
import { CardGrid } from '../components/CardGrid'
import { StatCard } from '../components/StatCard'
import { ChartBox } from '../components/ChartBox'
import { DataTable } from '../components/DataTable'
import { Pagination } from '../components/Pagination'
import { Badge } from '../components/Badge'
import { CommandChart } from '../charts/CommandChart'
import { CommandStatusChart } from '../charts/CommandStatusChart'
import { usePagination } from '../hooks/usePagination'
import { fmtNum, fmtDate } from '../utils'

export function CommandsPage() {
  const { dashboard: dashData } = useAuth()
  const [commands, setCommands] = useState<AdminCommand[]>([])
  const [statusFilter, setStatusFilter] = useState('')
  const [cmdPoints, setCmdPoints] = useState<TimeseriesPoint[]>([])
  const pag = usePagination()

  const load = useCallback(async () => {
    try {
      const data = await api<{ commands: AdminCommand[]; total: number }>(
        `/v1/admin/commands?status=${encodeURIComponent(statusFilter)}&limit=${pag.pageSize}&offset=${pag.offset}`,
      )
      setCommands(data.commands ?? [])
      pag.setTotal(data.total)
    } catch {
      // handled
    }
  }, [statusFilter, pag.offset, pag.pageSize, pag.setTotal])

  useEffect(() => {
    load()
  }, [load])

  useEffect(() => {
    api<{ points: TimeseriesPoint[] }>('/v1/admin/timeseries?metric=commands&days=30')
      .then((cp) => setCmdPoints(cp.points ?? []))
      .catch(() => {})
  }, [])

  const c = dashData?.stats?.commandsByStatus ?? {}

  const statusBadge = (status: string) => {
    const v =
      status === 'completed'
        ? 'green'
        : status === 'failed'
          ? 'red'
          : status === 'cancelled'
            ? 'yellow'
            : 'blue'
    return <Badge text={status} variant={v as 'green' | 'red' | 'yellow' | 'blue'} />
  }

  return (
    <div>
      <PageHeader title="Commands" subtitle="View remote commands" />
      {dashData && (
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
      )}
      {dashData && (
        <div className="chart-row">
          <ChartBox title="Commands per Day (30d)">
            <CommandChart points={cmdPoints} />
          </ChartBox>
          <ChartBox title="Command Status">
            <CommandStatusChart statuses={dashData.stats.commandsByStatus} />
          </ChartBox>
        </div>
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
            <option value="pending">Pending</option>
            <option value="completed">Completed</option>
            <option value="failed">Failed</option>
            <option value="cancelled">Cancelled</option>
          </select>
        </div>
        <DataTable
          columns={[
            {
              header: 'ID',
              render: (c: AdminCommand) => (
                <span title={c.id}>{c.id.substring(0, 8)}</span>
              ),
            },
            {
              header: 'Session',
              render: (c: AdminCommand) => (
                <span title={c.sessionId}>{c.sessionId.substring(0, 8)}</span>
              ),
            },
            { header: 'User', render: (c: AdminCommand) => c.userEmail },
            { header: 'Type', render: (c: AdminCommand) => c.type },
            { header: 'Status', render: (c: AdminCommand) => statusBadge(c.status) },
            {
              header: 'Prompt',
              render: (c: AdminCommand) => (
                <span
                  title={c.prompt}
                  style={{
                    maxWidth: 200,
                    overflow: 'hidden',
                    textOverflow: 'ellipsis',
                    whiteSpace: 'nowrap',
                    display: 'inline-block',
                  }}
                >
                  {c.prompt || '(empty)'}
                </span>
              ),
            },
            { header: 'Created', render: (c: AdminCommand) => fmtDate(c.createdAt) },
          ]}
          data={commands}
          emptyText="No commands found"
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
    </div>
  )
}
