import { useState, useEffect, useCallback, useRef } from 'react'
import type { AdminAppLog } from '../types'
import { api } from '../api'
import { PageHeader } from '../components/PageHeader'
import { DataTable } from '../components/DataTable'
import { Pagination } from '../components/Pagination'
import { Badge } from '../components/Badge'
import { usePagination } from '../hooks/usePagination'
import { fmtDate } from '../utils'

export function LogsPage() {
  const [logs, setLogs] = useState<AdminAppLog[]>([])
  const [levelFilter, setLevelFilter] = useState('')
  const [sourceFilter, setSourceFilter] = useState('')
  const [emailFilter, setEmailFilter] = useState('')
  const [emailInput, setEmailInput] = useState('')
  const [subsystemFilter, setSubsystemFilter] = useState('')
  const [selected, setSelected] = useState<AdminAppLog | null>(null)
  const pag = usePagination()
  const emailDebounce = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)

  const buildParams = useCallback(() => {
    const params = new URLSearchParams()
    if (levelFilter) params.set('level', levelFilter)
    if (sourceFilter) params.set('source', sourceFilter)
    if (emailFilter) params.set('email', emailFilter)
    if (subsystemFilter) params.set('subsystem', subsystemFilter)
    return params
  }, [levelFilter, sourceFilter, emailFilter, subsystemFilter])

  const load = useCallback(async () => {
    try {
      const params = buildParams()
      params.set('limit', String(pag.pageSize))
      params.set('offset', String(pag.offset))
      const data = await api<{ logs: AdminAppLog[]; total: number }>(
        `/v1/admin/logs?${params}`,
      )
      setLogs(data.logs ?? [])
      pag.setTotal(data.total)
    } catch {
      // handled by api
    }
  }, [buildParams, pag.offset, pag.pageSize, pag.setTotal])

  useEffect(() => {
    load()
  }, [load])

  const handleExport = () => {
    const params = buildParams()
    window.open(`/v1/admin/logs/export?${params}`, '_blank')
  }

  const levelBadge = (level: string) => {
    const v =
      level === 'error'
        ? 'red'
        : level === 'warn'
          ? 'yellow'
          : level === 'debug'
            ? 'blue'
            : 'green'
    return <Badge text={level} variant={v as 'green' | 'red' | 'yellow' | 'blue'} />
  }

  const sourceBadge = (source: string) => {
    const v = source === 'agent' ? 'blue' : 'green'
    return <Badge text={source} variant={v as 'green' | 'blue'} />
  }

  return (
    <div>
      <PageHeader title="Logs" subtitle="Application logs from agents and iOS clients" />
      <div className="table-wrap">
        <div className="table-controls">
          <select
            value={levelFilter}
            onChange={(e) => {
              setLevelFilter(e.target.value)
              pag.reset()
            }}
          >
            <option value="">All Levels</option>
            <option value="debug">Debug</option>
            <option value="info">Info</option>
            <option value="warn">Warn</option>
            <option value="error">Error</option>
          </select>
          <select
            value={sourceFilter}
            onChange={(e) => {
              setSourceFilter(e.target.value)
              pag.reset()
            }}
          >
            <option value="">All Sources</option>
            <option value="agent">Agent</option>
            <option value="ios">iOS</option>
          </select>
          <input
            type="text"
            placeholder="Filter by email..."
            value={emailInput}
            onChange={(e) => {
              const val = e.target.value
              setEmailInput(val)
              clearTimeout(emailDebounce.current)
              emailDebounce.current = setTimeout(() => {
                setEmailFilter(val)
                pag.reset()
              }, 400)
            }}
            style={{ minWidth: 180 }}
          />
          <input
            type="text"
            placeholder="Filter by subsystem..."
            value={subsystemFilter}
            onChange={(e) => {
              setSubsystemFilter(e.target.value)
              pag.reset()
            }}
            style={{ minWidth: 150 }}
          />
          <button
            className="btn-sm"
            onClick={handleExport}
            title="Export filtered logs as CSV"
            style={{ marginLeft: 'auto' }}
          >
            Export CSV
          </button>
        </div>
        <DataTable
          columns={[
            { header: 'Time', render: (l: AdminAppLog) => fmtDate(l.createdAt) },
            { header: 'Level', render: (l: AdminAppLog) => levelBadge(l.level) },
            { header: 'Source', render: (l: AdminAppLog) => sourceBadge(l.source) },
            { header: 'Subsystem', render: (l: AdminAppLog) => l.subsystem || '\u2014' },
            { header: 'User', render: (l: AdminAppLog) => l.userEmail },
            {
              header: 'Message',
              render: (l: AdminAppLog) => (
                <span
                  style={{
                    maxWidth: 300,
                    overflow: 'hidden',
                    textOverflow: 'ellipsis',
                    whiteSpace: 'nowrap',
                    display: 'inline-block',
                    cursor: 'pointer',
                  }}
                  onClick={() => setSelected(l)}
                >
                  {l.message}
                </span>
              ),
            },
            {
              header: 'Device',
              render: (l: AdminAppLog) => (
                <span title={l.deviceId}>{l.deviceId ? l.deviceId.substring(0, 8) : '\u2014'}</span>
              ),
            },
          ]}
          data={logs}
          emptyText="No logs found"
          onRowClick={(l: AdminAppLog) => setSelected(l)}
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

      {selected && (
        <div className="confirm-overlay" onClick={() => setSelected(null)}>
          <div className="detail-modal" onClick={(e) => e.stopPropagation()}>
            <button className="detail-modal-close" onClick={() => setSelected(null)}>&times;</button>
            <h3>Log Detail</h3>
            <div className="detail-field">
              <div className="detail-field-label">Time</div>
              <div className="detail-field-value">{fmtDate(selected.createdAt)}</div>
            </div>
            <div className="detail-field">
              <div className="detail-field-label">Level</div>
              <div className="detail-field-value">{levelBadge(selected.level)}</div>
            </div>
            <div className="detail-field">
              <div className="detail-field-label">Source</div>
              <div className="detail-field-value">{sourceBadge(selected.source)}</div>
            </div>
            <div className="detail-field">
              <div className="detail-field-label">Subsystem</div>
              <div className="detail-field-value">{selected.subsystem || '\u2014'}</div>
            </div>
            <div className="detail-field">
              <div className="detail-field-label">User</div>
              <div className="detail-field-value">{selected.userEmail}</div>
            </div>
            <div className="detail-field">
              <div className="detail-field-label">Device</div>
              <div className="detail-field-value">{selected.deviceId || '\u2014'}</div>
            </div>
            <div className="detail-field">
              <div className="detail-field-label">Message</div>
              <div className="detail-field-value">{selected.message}</div>
            </div>
            {selected.metadata && selected.metadata !== '{}' && (
              <div className="detail-field">
                <div className="detail-field-label">Metadata</div>
                <div className="detail-field-value" style={{ fontFamily: 'monospace', fontSize: 12 }}>
                  {selected.metadata}
                </div>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  )
}
