import { useState, useEffect, useCallback } from 'react'
import type { AdminUser } from '../types'
import { api } from '../api'
import { DataTable } from '../components/DataTable'
import { Pagination } from '../components/Pagination'
import { Badge } from '../components/Badge'
import { usePagination } from '../hooks/usePagination'
import { fmtDate } from '../utils'

export function UsersTable() {
  const [users, setUsers] = useState<AdminUser[]>([])
  const [search, setSearch] = useState('')
  const pag = usePagination()

  const load = useCallback(async () => {
    const data = await api<{ users: AdminUser[]; total: number }>(
      `/v1/admin/users?search=${encodeURIComponent(search)}&limit=${pag.pageSize}&offset=${pag.offset}`,
    )
    setUsers(data.users ?? [])
    pag.setTotal(data.total)
  }, [search, pag.offset, pag.pageSize, pag.setTotal])

  useEffect(() => {
    load()
  }, [load])

  const doSearch = () => {
    pag.reset()
    // reset triggers offset change which triggers load via useEffect
  }

  return (
    <div className="section">
      <h2>Users</h2>
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
            { header: 'Devices', render: (u: AdminUser) => u.deviceCount },
            { header: 'Sessions', render: (u: AdminUser) => u.sessionCount },
            { header: 'Registered', render: (u: AdminUser) => fmtDate(u.createdAt) },
          ]}
          data={users}
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
    </div>
  )
}
