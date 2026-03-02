import { useState, useEffect, useCallback } from 'react'
import type { AuditEntry, LoginAttempt, LoginAttemptsResponse, StaleDevice } from '../types'
import { api } from '../api'
import { PageHeader } from '../components/PageHeader'
import { CardGrid } from '../components/CardGrid'
import { StatCard } from '../components/StatCard'
import { DataTable } from '../components/DataTable'
import { Pagination } from '../components/Pagination'
import { Badge } from '../components/Badge'
import { TabGroup } from '../components/TabGroup'
import { usePagination } from '../hooks/usePagination'
import { fmtNum, fmtDate } from '../utils'

function AuditTab() {
  const [entries, setEntries] = useState<AuditEntry[]>([])
  const [action, setAction] = useState('')
  const [userId, setUserId] = useState('')
  const pag = usePagination()

  const load = useCallback(async () => {
    const data = await api<{ entries: AuditEntry[]; total: number }>(
      `/v1/admin/audit?action=${encodeURIComponent(action)}&user_id=${encodeURIComponent(userId)}&limit=${pag.pageSize}&offset=${pag.offset}`,
    )
    setEntries(data.entries ?? [])
    pag.setTotal(data.total)
  }, [action, userId, pag.offset, pag.pageSize, pag.setTotal])

  useEffect(() => {
    load()
  }, [load])

  const doFilter = () => pag.reset()

  const parseDetails = (details: string): string => {
    try {
      const d = JSON.parse(details)
      return Object.entries(d)
        .map(([k, v]) => `${k}=${v}`)
        .join(', ')
    } catch {
      return details
    }
  }

  return (
    <>
      <div className="table-controls">
        <input
          type="text"
          placeholder="Filter by action..."
          value={action}
          onChange={(e) => setAction(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && doFilter()}
        />
        <input
          type="text"
          placeholder="Filter by user ID..."
          value={userId}
          onChange={(e) => setUserId(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && doFilter()}
        />
        <button className="btn-sm" onClick={doFilter}>
          Filter
        </button>
      </div>
      <DataTable
        columns={[
          { header: 'Time', render: (e: AuditEntry) => fmtDate(e.createdAt) },
          {
            header: 'Action',
            render: (e: AuditEntry) => <Badge text={e.action} variant="blue" />,
          },
          {
            header: 'User',
            render: (e: AuditEntry) => (
              <span title={e.userId}>{e.userEmail || e.userId.substring(0, 8)}</span>
            ),
          },
          { header: 'IP', render: (e: AuditEntry) => e.ipAddress || '' },
          {
            header: 'Details',
            render: (e: AuditEntry) => {
              const text = parseDetails(e.details)
              return (
                <span
                  title={text}
                  style={{
                    maxWidth: 300,
                    overflow: 'hidden',
                    textOverflow: 'ellipsis',
                    whiteSpace: 'nowrap',
                    display: 'inline-block',
                  }}
                >
                  {text}
                </span>
              )
            },
          },
        ]}
        data={entries}
        emptyText="No entries"
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
    </>
  )
}

function LoginsTab() {
  const [attempts, setAttempts] = useState<LoginAttempt[]>([])
  const [filter, setFilter] = useState('')
  const pag = usePagination()

  const load = useCallback(async () => {
    const data = await api<{ attempts: LoginAttempt[]; total: number }>(
      `/v1/admin/login-attempts?success=${filter}&limit=${pag.pageSize}&offset=${pag.offset}`,
    )
    setAttempts(data.attempts ?? [])
    pag.setTotal(data.total)
  }, [filter, pag.offset, pag.pageSize, pag.setTotal])

  useEffect(() => {
    load()
  }, [load])

  return (
    <>
      <div className="table-controls">
        <select
          value={filter}
          onChange={(e) => {
            setFilter(e.target.value)
            pag.reset()
          }}
        >
          <option value="">All</option>
          <option value="true">Success</option>
          <option value="false">Failed</option>
        </select>
      </div>
      <DataTable
        columns={[
          { header: 'Time', render: (a: LoginAttempt) => fmtDate(a.attemptedAt) },
          { header: 'Email', render: (a: LoginAttempt) => a.email },
          {
            header: 'Status',
            render: (a: LoginAttempt) =>
              a.success ? (
                <Badge text="Success" variant="green" />
              ) : (
                <Badge text="Failed" variant="red" />
              ),
          },
          { header: 'IP', render: (a: LoginAttempt) => a.ipAddress || '' },
        ]}
        data={attempts}
        emptyText="No login attempts"
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
    </>
  )
}

function StaleDevicesTab() {
  const [devices, setDevices] = useState<StaleDevice[]>([])

  useEffect(() => {
    api<{ devices: StaleDevice[] }>('/v1/admin/stale-devices?days=30').then((data) =>
      setDevices(data.devices ?? []),
    )
  }, [])

  return (
    <DataTable
      columns={[
        { header: 'Device', render: (d: StaleDevice) => d.name },
        {
          header: 'User ID',
          render: (d: StaleDevice) => (
            <span title={d.userId}>{d.userId.substring(0, 8)}...</span>
          ),
        },
        { header: 'Last Seen', render: (d: StaleDevice) => fmtDate(d.lastSeenAt) },
      ]}
      data={devices}
      emptyText="No stale devices"
    />
  )
}

export function SecurityPage() {
  const [activeTab, setActiveTab] = useState('audit')
  const [failedLastHour, setFailedLastHour] = useState(0)
  const [failedLast24Hours, setFailedLast24Hours] = useState(0)

  useEffect(() => {
    api<LoginAttemptsResponse>('/v1/admin/login-attempts?limit=1&success=false').then((data) => {
      setFailedLastHour(data.failedLastHour)
      setFailedLast24Hours(data.failedLast24Hours)
    })
  }, [])

  return (
    <div>
      <PageHeader title="Security" subtitle="Audit logs and login monitoring" />
      <CardGrid>
        <StatCard
          label="Failed Logins (1h)"
          value={fmtNum(failedLastHour)}
          colorClass={failedLastHour > 0 ? 'red' : undefined}
        />
        <StatCard
          label="Failed Logins (24h)"
          value={fmtNum(failedLast24Hours)}
          colorClass={failedLast24Hours > 5 ? 'red' : undefined}
        />
      </CardGrid>
      <div className="table-wrap">
        <TabGroup
          tabs={[
            { key: 'audit', label: 'Audit Log', content: <AuditTab /> },
            { key: 'logins', label: 'Login Attempts', content: <LoginsTab /> },
            { key: 'stale', label: 'Stale Devices', content: <StaleDevicesTab /> },
          ]}
          activeTab={activeTab}
          onTabChange={setActiveTab}
        />
      </div>
    </div>
  )
}
