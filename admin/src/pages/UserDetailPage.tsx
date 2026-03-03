import { useState, useEffect, useCallback } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import type { AdminUserDetail, AdminDevice, AdminSession } from '../types'
import { api, apiPut, apiDelete, apiPost } from '../api'
import { PageHeader } from '../components/PageHeader'
import { CardGrid } from '../components/CardGrid'
import { StatCard } from '../components/StatCard'
import { DataTable } from '../components/DataTable'
import { Badge } from '../components/Badge'
import { ActionButton } from '../components/ActionButton'
import { ConfirmDialog } from '../components/ConfirmDialog'
import { DropdownMenu } from '../components/DropdownMenu'
import { useToast } from '../contexts/ToastContext'
import { fmtDate } from '../utils'

const tierOptions = [
  { label: 'Free', value: 'free' },
  { label: 'Pro', value: 'pro' },
  { label: 'Contributor', value: 'contributor' },
]

export function UserDetailPage() {
  const { id } = useParams<{ id: string }>()
  const nav = useNavigate()
  const { showToast } = useToast()
  const [detail, setDetail] = useState<AdminUserDetail | null>(null)
  const [loading, setLoading] = useState(true)
  const [confirm, setConfirm] = useState<{ type: string; id: string; label: string } | null>(null)
  const [actionLoading, setActionLoading] = useState(false)

  const load = useCallback(async () => {
    try {
      const data = await api<AdminUserDetail>(`/v1/admin/users/${id}`)
      setDetail(data)
    } catch {
      // handled by api
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
    return <div style={{ color: 'var(--text-dim)', padding: 40 }}>User not found</div>
  }

  const u = detail.user

  const changeTier = async (tier: string) => {
    if (tier === u.subscriptionTier) return
    try {
      await apiPut(`/v1/admin/users/${id}/tier`, { tier })
      showToast(`Tier changed to ${tier}`)
      load()
    } catch (e) {
      showToast(e instanceof Error ? e.message : 'Failed', 'error')
    }
  }

  const doConfirmAction = async () => {
    if (!confirm) return
    setActionLoading(true)
    try {
      if (confirm.type === 'revoke-device') {
        await apiDelete(`/v1/admin/devices/${confirm.id}`, { userId: id })
        showToast('Device revoked')
      } else if (confirm.type === 'rotate-keys') {
        await apiPost(`/v1/admin/devices/${confirm.id}/rotate-keys`, { userId: id })
        showToast('Keys rotated')
      } else if (confirm.type === 'force-end') {
        await apiPut(`/v1/admin/sessions/${confirm.id}/status`, { status: 'completed' })
        showToast('Session ended')
      }
      setConfirm(null)
      load()
    } catch (e) {
      showToast(e instanceof Error ? e.message : 'Failed', 'error')
    } finally {
      setActionLoading(false)
    }
  }

  return (
    <div>
      <PageHeader
        title={u.email}
        subtitle={u.displayName || u.id}
        actions={
          <div style={{ display: 'flex', gap: 8 }}>
            <DropdownMenu
              options={tierOptions}
              onSelect={changeTier}
              label="Change Tier"
            />
            <button className="btn-sm" onClick={() => nav('/users')}>
              Back
            </button>
          </div>
        }
      />
      <CardGrid>
        <StatCard label="Tier" value={u.subscriptionTier} />
        <StatCard label="Auth" value={u.authMethod} />
        <StatCard label="Devices" value={String(u.deviceCount)} />
        <StatCard label="Sessions" value={String(u.sessionCount)} />
        <StatCard label="Registered" value={fmtDate(u.createdAt)} />
      </CardGrid>

      <div className="section">
        <h2>Devices</h2>
        <div className="table-wrap">
          <DataTable
            columns={[
              { header: 'Name', render: (d: AdminDevice) => d.name },
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
                  d.e2eeEnabled ? (
                    <Badge text="Yes" variant="green" />
                  ) : (
                    <span style={{ color: 'var(--text-dim)' }}>No</span>
                  ),
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
                        onClick={() =>
                          setConfirm({ type: 'revoke-device', id: d.id, label: d.name })
                        }
                      />
                      <ActionButton
                        label="Rotate Keys"
                        onClick={() =>
                          setConfirm({ type: 'rotate-keys', id: d.id, label: d.name })
                        }
                      />
                    </div>
                  ),
              },
            ]}
            data={detail.devices}
            emptyText="No devices"
          />
        </div>
      </div>

      <div className="section">
        <h2>Recent Sessions</h2>
        <div className="table-wrap">
          <DataTable
            columns={[
              {
                header: 'ID',
                render: (s: AdminSession) => (
                  <span title={s.id}>{s.id.substring(0, 8)}</span>
                ),
              },
              {
                header: 'Status',
                render: (s: AdminSession) => {
                  const v =
                    s.status === 'completed'
                      ? 'green'
                      : s.status === 'running'
                        ? 'blue'
                        : 'yellow'
                  return <Badge text={s.status} variant={v as 'green' | 'blue' | 'yellow'} />
                },
              },
              { header: 'Project', render: (s: AdminSession) => s.projectName || 'N/A' },
              { header: 'Started', render: (s: AdminSession) => fmtDate(s.startedAt) },
              {
                header: 'Actions',
                render: (s: AdminSession) =>
                  s.status === 'running' || s.status === 'idle' ? (
                    <ActionButton
                      label="Force End"
                      variant="danger"
                      onClick={() =>
                        setConfirm({ type: 'force-end', id: s.id, label: s.id.substring(0, 8) })
                      }
                    />
                  ) : null,
              },
            ]}
            data={detail.recentSessions}
            onRowClick={(s) => nav(`/sessions/${s.id}`)}
            emptyText="No sessions"
          />
        </div>
      </div>

      <ConfirmDialog
        open={!!confirm}
        title={
          confirm?.type === 'revoke-device'
            ? 'Revoke Device'
            : confirm?.type === 'rotate-keys'
              ? 'Force Key Rotation'
              : 'Force End Session'
        }
        message={
          confirm?.type === 'revoke-device'
            ? `Revoke device "${confirm.label}"? This will disable the device and revoke its keys.`
            : confirm?.type === 'rotate-keys'
              ? `Force key rotation for "${confirm.label}"? Connected clients will need to re-negotiate keys.`
              : `Force end session ${confirm?.label}?`
        }
        confirmLabel={
          confirm?.type === 'revoke-device'
            ? 'Revoke'
            : confirm?.type === 'rotate-keys'
              ? 'Rotate'
              : 'End Session'
        }
        confirmVariant="danger"
        loading={actionLoading}
        onConfirm={doConfirmAction}
        onCancel={() => setConfirm(null)}
      />
    </div>
  )
}
