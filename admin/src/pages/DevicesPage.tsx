import { useState, useEffect, useCallback } from 'react'
import type { AdminDevice } from '../types'
import { api, apiDelete, apiPost } from '../api'
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
import { PrivacyModeChart } from '../charts/PrivacyModeChart'
import { useToast } from '../contexts/ToastContext'
import { usePagination } from '../hooks/usePagination'
import { fmtNum, fmtDate } from '../utils'

export function DevicesPage() {
  const { showToast } = useToast()
  const { dashboard: dashData } = useAuth()
  const [devices, setDevices] = useState<AdminDevice[]>([])
  const [search, setSearch] = useState('')
  const pag = usePagination()
  const [confirm, setConfirm] = useState<{ type: string; device: AdminDevice } | null>(null)
  const [actionLoading, setActionLoading] = useState(false)

  const load = useCallback(async () => {
    try {
      const data = await api<{ devices: AdminDevice[]; total: number }>(
        `/v1/admin/devices?search=${encodeURIComponent(search)}&limit=${pag.pageSize}&offset=${pag.offset}`,
      )
      setDevices(data.devices ?? [])
      pag.setTotal(data.total)
    } catch {
      // handled
    }
  }, [search, pag.offset, pag.pageSize, pag.setTotal])

  useEffect(() => {
    load()
  }, [load])

  const doSearch = () => pag.reset()

  const doAction = async () => {
    if (!confirm) return
    setActionLoading(true)
    try {
      if (confirm.type === 'revoke') {
        await apiDelete(`/v1/admin/devices/${confirm.device.id}`, { userId: confirm.device.userId })
        showToast('Device revoked')
      } else {
        await apiPost(`/v1/admin/devices/${confirm.device.id}/rotate-keys`, {
          userId: confirm.device.userId,
        })
        showToast('Keys rotated')
      }
      setConfirm(null)
      load()
    } catch (e) {
      showToast(e instanceof Error ? e.message : 'Failed', 'error')
    } finally {
      setActionLoading(false)
    }
  }

  const s = dashData?.stats

  return (
    <div>
      <PageHeader title="Devices" subtitle="Manage registered devices" />
      {s && (
        <CardGrid>
          <StatCard label="Total Devices" value={fmtNum(s.totalDevices)} />
          <StatCard label="Online" value={fmtNum(s.onlineDevices)} colorClass="green" />
          <StatCard label="E2EE Enabled" value={fmtNum(s.e2eeDevices)} colorClass="accent" />
          <StatCard
            label="Stale (30d+)"
            value={fmtNum(s.staleDevices)}
            colorClass={s.staleDevices > 0 ? 'yellow' : undefined}
          />
        </CardGrid>
      )}
      {s && (
        <div className="chart-row">
          <ChartBox title="Privacy Modes">
            <PrivacyModeChart modes={s.byPrivacyMode} />
          </ChartBox>
        </div>
      )}
      <div className="table-wrap">
        <div className="table-controls">
          <input
            type="text"
            placeholder="Search device name or user email..."
            style={{ flex: 1, minWidth: 200 }}
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            onKeyDown={(e) => e.key === 'Enter' && doSearch()}
          />
          <button className="btn-sm" onClick={doSearch}>
            Search
          </button>
        </div>
        <DataTable
          columns={[
            { header: 'Name', render: (d: AdminDevice) => d.name },
            { header: 'User', render: (d: AdminDevice) => d.userEmail },
            { header: 'Platform', render: (d: AdminDevice) => d.platform },
            {
              header: 'Status',
              render: (d: AdminDevice) =>
                d.isRevoked ? (
                  <Badge text="Revoked" variant="red" />
                ) : d.isOnline ? (
                  <Badge text="Online" variant="green" />
                ) : (
                  <Badge text="Offline" variant="yellow" />
                ),
            },
            { header: 'Privacy', render: (d: AdminDevice) => d.privacyMode },
            {
              header: 'E2EE',
              render: (d: AdminDevice) =>
                d.e2eeEnabled ? <Badge text="Yes" variant="green" /> : <span style={{ color: 'var(--text-dim)' }}>No</span>,
            },
            { header: 'Last Seen', render: (d: AdminDevice) => fmtDate(d.lastSeenAt) },
            {
              header: 'Actions',
              render: (d: AdminDevice) =>
                d.isRevoked ? null : (
                  <div style={{ display: 'flex', gap: 4 }}>
                    <ActionButton
                      label="Revoke"
                      variant="danger"
                      onClick={() => setConfirm({ type: 'revoke', device: d })}
                    />
                    <ActionButton
                      label="Rotate Keys"
                      onClick={() => setConfirm({ type: 'rotate', device: d })}
                    />
                  </div>
                ),
            },
          ]}
          data={devices}
          emptyText="No devices found"
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
        open={!!confirm}
        title={confirm?.type === 'revoke' ? 'Revoke Device' : 'Force Key Rotation'}
        message={
          confirm?.type === 'revoke'
            ? `Revoke "${confirm.device.name}"? This disables the device and revokes its keys.`
            : `Force key rotation for "${confirm?.device.name}"? Connected clients will need to re-negotiate keys.`
        }
        confirmLabel={confirm?.type === 'revoke' ? 'Revoke' : 'Rotate'}
        confirmVariant="danger"
        loading={actionLoading}
        onConfirm={doAction}
        onCancel={() => setConfirm(null)}
      />
    </div>
  )
}
