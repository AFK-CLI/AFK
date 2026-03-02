import { useState } from 'react'
import { Outlet } from 'react-router-dom'
import { Sidebar } from './Sidebar'
import { useAuth } from '../contexts/AuthContext'

export function AppLayout() {
  const { logout, dashboard } = useAuth()
  const [sidebarOpen, setSidebarOpen] = useState(false)

  return (
    <div className="app-layout">
      <button
        className="hamburger"
        onClick={() => setSidebarOpen(!sidebarOpen)}
        aria-label="Toggle menu"
      >
        &#9776;
      </button>
      <Sidebar
        version={dashboard?.runtime.version ?? '...'}
        uptime={dashboard?.runtime.uptime ?? 0}
        onLogout={logout}
        open={sidebarOpen}
        onClose={() => setSidebarOpen(false)}
      />
      <main className="main-content">
        <Outlet />
      </main>
    </div>
  )
}
