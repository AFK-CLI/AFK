import { useState, useEffect, useCallback } from 'react'
import type { BetaRequest } from '../types'
import { api, apiPut } from '../api'
import { PageHeader } from '../components/PageHeader'
import { DataTable } from '../components/DataTable'
import { Pagination } from '../components/Pagination'
import { Badge } from '../components/Badge'
import { usePagination } from '../hooks/usePagination'
import { fmtDate } from '../utils'
import { useToast } from '../contexts/ToastContext'

export function BetaPage() {
  const [requests, setRequests] = useState<BetaRequest[]>([])
  const [statusFilter, setStatusFilter] = useState('')
  const [selected, setSelected] = useState<BetaRequest | null>(null)
  const pag = usePagination()
  const { showToast } = useToast()

  const load = useCallback(async () => {
    try {
      const params = new URLSearchParams()
      if (statusFilter) params.set('status', statusFilter)
      params.set('limit', String(pag.pageSize))
      params.set('offset', String(pag.offset))
      const data = await api<{ requests: BetaRequest[]; total: number }>(
        `/v1/admin/beta-requests?${params}`,
      )
      setRequests(data.requests ?? [])
      pag.setTotal(data.total)
    } catch {
      // handled by api
    }
  }, [statusFilter, pag.offset, pag.pageSize, pag.setTotal])

  useEffect(() => {
    load()
  }, [load])

  const updateStatus = async (id: string, status: string, notes?: string) => {
    try {
      await apiPut(`/v1/admin/beta-requests/${id}`, { status, notes: notes || '' })
      showToast(`Marked as ${status}`, 'success')
      load()
      setSelected(null)
    } catch (err) {
      showToast(String(err), 'error')
    }
  }

  const statusBadge = (status: string) => {
    const v =
      status === 'invited'
        ? 'green'
        : status === 'declined'
          ? 'red'
          : 'yellow'
    return <Badge text={status} variant={v as 'green' | 'red' | 'yellow'} />
  }

  const pendingCount = requests.filter((r) => r.status === 'pending').length

  return (
    <div>
      <PageHeader
        title="Beta Requests"
        subtitle={`Manage TestFlight beta access requests${statusFilter === '' && pendingCount > 0 ? ` \u2014 ${pendingCount} pending` : ''}`}
      />
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
            <option value="invited">Invited</option>
            <option value="declined">Declined</option>
          </select>
        </div>
        <DataTable
          columns={[
            { header: 'Time', render: (r: BetaRequest) => fmtDate(r.createdAt) },
            { header: 'Email', render: (r: BetaRequest) => r.email },
            { header: 'Name', render: (r: BetaRequest) => r.name || '\u2014' },
            { header: 'Status', render: (r: BetaRequest) => statusBadge(r.status) },
            {
              header: 'Notes',
              render: (r: BetaRequest) => (
                <span
                  style={{
                    maxWidth: 200,
                    overflow: 'hidden',
                    textOverflow: 'ellipsis',
                    whiteSpace: 'nowrap',
                    display: 'inline-block',
                  }}
                >
                  {r.notes || '\u2014'}
                </span>
              ),
            },
            {
              header: 'Actions',
              render: (r: BetaRequest) => (
                <div style={{ display: 'flex', gap: 6 }}>
                  {r.status !== 'invited' && (
                    <button
                      className="btn-sm btn-green"
                      onClick={(e) => {
                        e.stopPropagation()
                        updateStatus(r.id, 'invited')
                      }}
                    >
                      Mark Invited
                    </button>
                  )}
                  {r.status !== 'declined' && (
                    <button
                      className="btn-sm btn-red"
                      onClick={(e) => {
                        e.stopPropagation()
                        updateStatus(r.id, 'declined')
                      }}
                    >
                      Decline
                    </button>
                  )}
                </div>
              ),
            },
          ]}
          data={requests}
          emptyText="No beta requests found"
          onRowClick={(r: BetaRequest) => setSelected(r)}
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
            <button className="detail-modal-close" onClick={() => setSelected(null)}>
              &times;
            </button>
            <h3>Beta Request Detail</h3>
            <div className="detail-field">
              <div className="detail-field-label">Time</div>
              <div className="detail-field-value">{fmtDate(selected.createdAt)}</div>
            </div>
            <div className="detail-field">
              <div className="detail-field-label">Email</div>
              <div className="detail-field-value">{selected.email}</div>
            </div>
            <div className="detail-field">
              <div className="detail-field-label">Name</div>
              <div className="detail-field-value">{selected.name || '\u2014'}</div>
            </div>
            <div className="detail-field">
              <div className="detail-field-label">Status</div>
              <div className="detail-field-value">{statusBadge(selected.status)}</div>
            </div>
            <div className="detail-field">
              <div className="detail-field-label">Notes</div>
              <div className="detail-field-value">{selected.notes || '\u2014'}</div>
            </div>
            {selected.invitedAt && (
              <div className="detail-field">
                <div className="detail-field-label">Invited At</div>
                <div className="detail-field-value">{fmtDate(selected.invitedAt)}</div>
              </div>
            )}
            <div style={{ display: 'flex', gap: 8, marginTop: 16 }}>
              {selected.status !== 'invited' && (
                <button
                  className="btn-sm btn-green"
                  onClick={() => updateStatus(selected.id, 'invited')}
                >
                  Mark Invited
                </button>
              )}
              {selected.status !== 'declined' && (
                <button
                  className="btn-sm btn-red"
                  onClick={() => updateStatus(selected.id, 'declined')}
                >
                  Decline
                </button>
              )}
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
