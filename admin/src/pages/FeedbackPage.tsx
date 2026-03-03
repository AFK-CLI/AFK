import { useState, useEffect, useCallback } from 'react'
import type { AdminFeedback } from '../types'
import { api } from '../api'
import { PageHeader } from '../components/PageHeader'
import { DataTable } from '../components/DataTable'
import { Pagination } from '../components/Pagination'
import { Badge } from '../components/Badge'
import { usePagination } from '../hooks/usePagination'
import { fmtDate } from '../utils'

export function FeedbackPage() {
  const [feedback, setFeedback] = useState<AdminFeedback[]>([])
  const [categoryFilter, setCategoryFilter] = useState('')
  const [selected, setSelected] = useState<AdminFeedback | null>(null)
  const pag = usePagination()

  const load = useCallback(async () => {
    try {
      const params = new URLSearchParams()
      if (categoryFilter) params.set('category', categoryFilter)
      params.set('limit', String(pag.pageSize))
      params.set('offset', String(pag.offset))
      const data = await api<{ feedback: AdminFeedback[]; total: number }>(
        `/v1/admin/feedback?${params}`,
      )
      setFeedback(data.feedback ?? [])
      pag.setTotal(data.total)
    } catch {
      // handled by api
    }
  }, [categoryFilter, pag.offset, pag.pageSize, pag.setTotal])

  useEffect(() => {
    load()
  }, [load])

  const categoryBadge = (cat: string) => {
    const v =
      cat === 'bug_report'
        ? 'red'
        : cat === 'feature_request'
          ? 'blue'
          : 'yellow'
    const label = cat.replace(/_/g, ' ')
    return <Badge text={label} variant={v as 'green' | 'red' | 'yellow' | 'blue'} />
  }

  const platformBadge = (platform: string) => {
    const v = platform === 'macos' ? 'blue' : 'green'
    return <Badge text={platform || 'unknown'} variant={v as 'green' | 'blue'} />
  }

  return (
    <div>
      <PageHeader title="Feedback" subtitle="User feedback and feature requests" />
      <div className="table-wrap">
        <div className="table-controls">
          <select
            value={categoryFilter}
            onChange={(e) => {
              setCategoryFilter(e.target.value)
              pag.reset()
            }}
          >
            <option value="">All Categories</option>
            <option value="bug_report">Bug Report</option>
            <option value="feature_request">Feature Request</option>
            <option value="general">General</option>
          </select>
        </div>
        <DataTable
          columns={[
            { header: 'Time', render: (f: AdminFeedback) => fmtDate(f.createdAt) },
            { header: 'Category', render: (f: AdminFeedback) => categoryBadge(f.category) },
            { header: 'User', render: (f: AdminFeedback) => f.userEmail },
            { header: 'Platform', render: (f: AdminFeedback) => platformBadge(f.platform) },
            {
              header: 'Version',
              render: (f: AdminFeedback) => f.appVersion || '\u2014',
            },
            {
              header: 'Message',
              render: (f: AdminFeedback) => (
                <span
                  style={{
                    maxWidth: 350,
                    overflow: 'hidden',
                    textOverflow: 'ellipsis',
                    whiteSpace: 'nowrap',
                    display: 'inline-block',
                  }}
                >
                  {f.message}
                </span>
              ),
            },
          ]}
          data={feedback}
          emptyText="No feedback found"
          onRowClick={(f: AdminFeedback) => setSelected(f)}
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
            <h3>Feedback Detail</h3>
            <div className="detail-field">
              <div className="detail-field-label">Time</div>
              <div className="detail-field-value">{fmtDate(selected.createdAt)}</div>
            </div>
            <div className="detail-field">
              <div className="detail-field-label">Category</div>
              <div className="detail-field-value">{categoryBadge(selected.category)}</div>
            </div>
            <div className="detail-field">
              <div className="detail-field-label">User</div>
              <div className="detail-field-value">{selected.userEmail}</div>
            </div>
            <div className="detail-field">
              <div className="detail-field-label">Platform</div>
              <div className="detail-field-value">{platformBadge(selected.platform)}</div>
            </div>
            <div className="detail-field">
              <div className="detail-field-label">Version</div>
              <div className="detail-field-value">{selected.appVersion || '\u2014'}</div>
            </div>
            <div className="detail-field">
              <div className="detail-field-label">Device</div>
              <div className="detail-field-value">{selected.deviceId || '\u2014'}</div>
            </div>
            <div className="detail-field">
              <div className="detail-field-label">Message</div>
              <div className="detail-field-value">{selected.message}</div>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
