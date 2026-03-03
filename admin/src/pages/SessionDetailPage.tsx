import { useState, useEffect, useCallback } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import type { AdminSessionDetailResponse, AdminCommand } from '../types'
import { api, apiPut } from '../api'
import { PageHeader } from '../components/PageHeader'
import { CardGrid } from '../components/CardGrid'
import { StatCard } from '../components/StatCard'
import { DataTable } from '../components/DataTable'
import { Badge } from '../components/Badge'
import { ConfirmDialog } from '../components/ConfirmDialog'
import { useToast } from '../contexts/ToastContext'
import { fmtDate, fmtDuration, fmtTokens } from '../utils'

export function SessionDetailPage() {
  const { id } = useParams<{ id: string }>()
  const nav = useNavigate()
  const { showToast } = useToast()
  const [detail, setDetail] = useState<AdminSessionDetailResponse | null>(null)
  const [loading, setLoading] = useState(true)
  const [showEnd, setShowEnd] = useState(false)
  const [actionLoading, setActionLoading] = useState(false)

  const load = useCallback(async () => {
    try {
      const data = await api<AdminSessionDetailResponse>(`/v1/admin/sessions/${id}`)
      setDetail(data)
    } catch {
      // handled
    } finally {
      setLoading(false)
    }
  }, [id])

  useEffect(() => {
    load()
  }, [load])

  if (loading) {
    return <div style={{ color: 'var(--text-dim)', padding: 40 }}>Loading...</div>
  }
  if (!detail) {
    return <div style={{ color: 'var(--text-dim)', padding: 40 }}>Session not found</div>
  }

  const s = detail.session
  const isActive = s.status === 'running' || s.status === 'idle'

  const doForceEnd = async () => {
    setActionLoading(true)
    try {
      await apiPut(`/v1/admin/sessions/${id}/status`, { status: 'completed' })
      showToast('Session force-ended')
      setShowEnd(false)
      load()
    } catch (e) {
      showToast(e instanceof Error ? e.message : 'Failed', 'error')
    } finally {
      setActionLoading(false)
    }
  }

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

  const start = new Date(s.startedAt).getTime()
  const end = new Date(s.updatedAt).getTime()
  const durationSec = (end - start) / 1000

  return (
    <div>
      <PageHeader
        title={`Session ${s.id.substring(0, 8)}`}
        subtitle={s.userEmail}
        actions={
          <div style={{ display: 'flex', gap: 8 }}>
            {isActive && (
              <button className="btn-sm btn-danger" onClick={() => setShowEnd(true)}>
                Force End
              </button>
            )}
            <button className="btn-sm" onClick={() => nav('/sessions')}>
              Back
            </button>
          </div>
        }
      />
      <CardGrid>
        <StatCard label="Status" value={s.status} />
        <StatCard label="Duration" value={fmtDuration(durationSec)} />
        <StatCard label="Turns" value={String(s.turnCount)} />
        <StatCard label="Tokens In" value={fmtTokens(s.tokensIn)} />
        <StatCard label="Tokens Out" value={fmtTokens(s.tokensOut)} />
      </CardGrid>
      <CardGrid>
        <StatCard label="Project" value={s.projectName || 'N/A'} />
        <StatCard label="Branch" value={s.gitBranch || 'N/A'} />
        <StatCard label="Started" value={fmtDate(s.startedAt)} />
        <StatCard label="Updated" value={fmtDate(s.updatedAt)} />
      </CardGrid>
      {s.description && (
        <div className="card" style={{ marginBottom: 16, padding: 16 }}>
          <div className="label">Description</div>
          <div style={{ marginTop: 4 }}>{s.description}</div>
        </div>
      )}

      <div className="section">
        <h2>Commands</h2>
        <div className="table-wrap">
          <DataTable
            columns={[
              {
                header: 'ID',
                render: (c: AdminCommand) => (
                  <span title={c.id}>{c.id.substring(0, 8)}</span>
                ),
              },
              { header: 'Type', render: (c: AdminCommand) => c.type },
              {
                header: 'Status',
                render: (c: AdminCommand) => statusBadge(c.status),
              },
              {
                header: 'Prompt',
                render: (c: AdminCommand) => (
                  <span
                    title={c.prompt}
                    style={{
                      maxWidth: 300,
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
            data={detail.commands}
            emptyText="No commands"
          />
        </div>
      </div>

      <ConfirmDialog
        open={showEnd}
        title="Force End Session"
        message={`Force end session ${s.id.substring(0, 8)}? This will mark it as completed.`}
        confirmLabel="End Session"
        confirmVariant="danger"
        loading={actionLoading}
        onConfirm={doForceEnd}
        onCancel={() => setShowEnd(false)}
      />
    </div>
  )
}
