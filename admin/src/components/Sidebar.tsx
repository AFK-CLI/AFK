import { NavLink } from 'react-router-dom'
import { fmtUptime } from '../utils'

interface Props {
  version: string
  uptime: number
  onLogout: () => void
  open: boolean
  onClose: () => void
}

const navItems = [
  { to: '/', label: 'Overview', end: true },
  { to: '/users', label: 'Users' },
  { to: '/devices', label: 'Devices' },
  { to: '/sessions', label: 'Sessions' },
  { to: '/commands', label: 'Commands' },
  { to: '/security', label: 'Security' },
  { to: '/logs', label: 'Logs' },
  { to: '/feedback', label: 'Feedback' },
  { to: '/beta', label: 'Beta Requests' },
  { to: '/server', label: 'Server' },
  { to: '/profile', label: 'Profile' },
]

const futureItems: { to: string; label: string; soon?: boolean }[] = []

export function Sidebar({ version, uptime, onLogout, open, onClose }: Props) {
  return (
    <>
      {open && <div className="sidebar-backdrop" onClick={onClose} />}
      <aside className={`sidebar ${open ? 'sidebar-open' : ''}`}>
        <div className="sidebar-header">
          <span className="sidebar-logo">AFK</span>
          <span className="sidebar-version">v{version}</span>
        </div>
        <nav className="sidebar-nav">
          {navItems.map((item) => (
            <NavLink
              key={item.to}
              to={item.to}
              end={item.end}
              className={({ isActive }) =>
                `sidebar-link ${isActive ? 'sidebar-link-active' : ''}`
              }
              onClick={onClose}
            >
              {item.label}
            </NavLink>
          ))}
          <div className="sidebar-divider" />
          {futureItems.map((item) => (
            <NavLink
              key={item.to}
              to={item.to}
              className={({ isActive }) =>
                `sidebar-link ${isActive ? 'sidebar-link-active' : ''}`
              }
              onClick={onClose}
            >
              {item.label}
              {item.soon && <span className="sidebar-soon">soon</span>}
            </NavLink>
          ))}
        </nav>
        <div className="sidebar-footer">
          <span className="sidebar-uptime">Up {fmtUptime(uptime)}</span>
          <button className="btn-sm" onClick={onLogout}>
            Logout
          </button>
        </div>
      </aside>
    </>
  )
}
