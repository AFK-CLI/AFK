import { useState, useEffect, useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import type { AdminUser } from '../types'
import { api, apiPut, apiDelete } from '../api'
import { DataTable } from '../components/DataTable'
import { Pagination } from '../components/Pagination'
import { Badge } from '../components/Badge'
import { PageHeader } from '../components/PageHeader'
import { ActionButton } from '../components/ActionButton'
import { DropdownMenu } from '../components/DropdownMenu'
import { ConfirmDialog } from '../components/ConfirmDialog'
import { useToast } from '../contexts/ToastContext'
import { usePagination } from '../hooks/usePagination'
import { fmtDate } from '../utils'

const tierOptions = [
  { label: 'Free', value: 'free' },
  { label: 'Pro', value: 'pro' },
  { label: 'Contributor', value: 'contributor' },
]

export function UsersPage() {
  const nav = useNavigate()
  const { showToast } = useToast()
  const [users, setUsers] = useState<AdminUser[]>([])
  const [search, setSearch] = useState('')
  const pag = usePagination()
  const [revokeTarget, setRevokeTarget] = useState<AdminUser | null>(null)
  const [revokeLoading, setRevokeLoading] = useState(false)
  const [tierLoading, setTierLoading] = useState<string | null>(null)

  const load = useCallback(async () => {
    try {
      const data = await api<{ users: AdminUser[]; total: number }>(
        `/v1/admin/users?search=${encodeURIComponent(search)}&limit=${pag.pageSize}&offset=${pag.offset}`,
      )
      setUsers(data.users ?? [])
      pag.setTotal(data.total)
    } catch {
      // handled by api
    }
  }, [search, pag.offset, pag.pageSize, pag.setTotal])

  useEffect(() => {
    load()
  }, [load])

  const doSearch = () => pag.reset()

  const changeTier = async (user: AdminUser, tier: string) => {
    if (tier === user.subscriptionTier) return
    setTierLoading(user.id)
    try {
      await apiPut(`/v1/admin/users/${user.id}/tier`, { tier })
      showToast(`Tier changed to ${tier}`)
      load()
    } catch (e) {
      showToast(e instanceof Error ? e.message : 'Failed to change tier', 'error')
    } finally {
      setTierLoading(null)
    }
  }

  const doRevoke = async () => {
    if (!revokeTarget) return
    setRevokeLoading(true)
    try {
      await apiDelete(`/v1/admin/users/${revokeTarget.id}`)
      showToast('User revoked')
      setRevokeTarget(null)
      load()
    } catch (e) {
      showToast(e instanceof Error ? e.message : 'Failed to revoke user', 'error')
    } finally {
      setRevokeLoading(false)
    }
  }

  return (
    <div>
      <PageHeader title="Users" subtitle="Manage user accounts and tiers" />
      <div className="table-wrap">
        <div className="table-controls">
          <input
            type="text"
            placeholder="Search email or name..."
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
            { header: 'Email', render: (u: AdminUser) => u.email },
            { header: 'Name', render: (u: AdminUser) => u.displayName },
            {
              header: 'Tier',
              render: (u: AdminUser) => <Badge text={u.subscriptionTier} variant="blue" />,
            },
            { header: 'Auth', render: (u: AdminUser) => u.authMethod },
            {
              header: 'Verified',
              render: (u: AdminUser) =>
                u.emailVerified ? (
                  <Badge text="Yes" variant="green" />
                ) : (
                  <Badge text="No" variant="red" />
                ),
            },
            { header: 'Devices', render: (u: AdminUser) => u.deviceCount },
            { header: 'Sessions', render: (u: AdminUser) => u.sessionCount },
            { header: 'Registered', render: (u: AdminUser) => fmtDate(u.createdAt) },
            {
              header: 'Actions',
              render: (u: AdminUser) => (
                <div style={{ display: 'flex', gap: 4 }}>
                  <DropdownMenu
                    options={tierOptions}
                    onSelect={(tier) => changeTier(u, tier)}
                    label={tierLoading === u.id ? '...' : 'Tier'}
                  />
                  <ActionButton
                    label="Revoke"
                    variant="danger"
                    onClick={() => setRevokeTarget(u)}
                  />
                </div>
              ),
            },
          ]}
          data={users}
          onRowClick={(u) => nav(`/users/${u.id}`)}
          emptyText="No users found"
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
        open={!!revokeTarget}
        title="Revoke User"
        message={`This will revoke ${revokeTarget?.email ?? 'this user'} and all their devices. This action cannot be undone.`}
        confirmLabel="Revoke"
        confirmVariant="danger"
        loading={revokeLoading}
        onConfirm={doRevoke}
        onCancel={() => setRevokeTarget(null)}
      />
    </div>
  )
}
