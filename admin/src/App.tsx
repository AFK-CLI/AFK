import { useState, useEffect, useCallback } from 'react'
import type {
  DashboardResponse,
  TimeseriesPoint,
  TokenTimeseriesPoint,
  AdminProject,
} from './types'
import { api, adminLogin, adminLogout, setOnUnauthorized } from './api'
import { fmtUptime } from './utils'
import { useAutoRefresh } from './hooks/useAutoRefresh'
import { ServerHealth } from './sections/ServerHealth'
import { UserAnalytics } from './sections/UserAnalytics'
import { Devices } from './sections/Devices'
import { Sessions } from './sections/Sessions'
import { Commands } from './sections/Commands'
import { PushNotifications } from './sections/PushNotifications'
import { UsersTable } from './sections/UsersTable'
import { Security } from './sections/Security'

function LoginScreen({ onLogin }: { onLogin: () => void }) {
  const [secret, setSecret] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)

  const doLogin = async () => {
    setLoading(true)
    setError('')
    try {
      await adminLogin(secret)
      onLogin()
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Connection error')
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="login-wrap">
      <div className="login-box">
        <h1>AFK Admin</h1>
        <p>Enter admin secret to continue</p>
        {error && <div className="login-error">{error}</div>}
        <input
          type="password"
          placeholder="Admin secret"
          autoFocus
          value={secret}
          onChange={(e) => setSecret(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && doLogin()}
        />
        <button onClick={doLogin} disabled={loading}>
          {loading ? 'Signing in...' : 'Sign In'}
        </button>
      </div>
    </div>
  )
}

function Dashboard({ onLogout }: { onLogout: () => void }) {
  const [dash, setDash] = useState<DashboardResponse | null>(null)
  const [regPoints, setRegPoints] = useState<TimeseriesPoint[]>([])
  const [sessPoints, setSessPoints] = useState<TimeseriesPoint[]>([])
  const [cmdPoints, setCmdPoints] = useState<TimeseriesPoint[]>([])
  const [tokPoints, setTokPoints] = useState<TokenTimeseriesPoint[]>([])
  const [projects, setProjects] = useState<AdminProject[]>([])

  const refresh = useCallback(async () => {
    try {
      const [dashData, regTS, sessTS, cmdTS, tokTS, topP] = await Promise.all([
        api<DashboardResponse>('/v1/admin/dashboard'),
        api<{ points: TimeseriesPoint[] }>('/v1/admin/timeseries?metric=registrations&days=30'),
        api<{ points: TimeseriesPoint[] }>('/v1/admin/timeseries?metric=sessions&days=30'),
        api<{ points: TimeseriesPoint[] }>('/v1/admin/timeseries?metric=commands&days=30'),
        api<{ points: TokenTimeseriesPoint[] }>('/v1/admin/timeseries?metric=tokens&days=30'),
        api<{ projects: AdminProject[] }>('/v1/admin/top-projects?limit=10'),
      ])
      setDash(dashData)
      setRegPoints(regTS.points ?? [])
      setSessPoints(sessTS.points ?? [])
      setCmdPoints(cmdTS.points ?? [])
      setTokPoints(tokTS.points ?? [])
      setProjects(topP.projects ?? [])
    } catch (e) {
      if (e instanceof Error && e.message !== 'unauthorized') {
        console.error('refresh failed:', e)
      }
    }
  }, [])

  useEffect(() => {
    refresh()
  }, [refresh])

  useAutoRefresh(refresh)

  const handleLogout = () => {
    adminLogout()
    onLogout()
  }

  if (!dash) {
    return (
      <div className="dashboard" style={{ textAlign: 'center', paddingTop: 100, color: 'var(--text-dim)' }}>
        Loading...
      </div>
    )
  }

  return (
    <div className="dashboard">
      <div className="header">
        <h1>AFK Admin Dashboard</h1>
        <div className="header-right">
          <span className="version">v{dash.runtime.version}</span>
          <span className="uptime">Up {fmtUptime(dash.runtime.uptime)}</span>
          <button className="btn-sm" onClick={refresh}>
            Refresh
          </button>
          <button className="btn-sm" onClick={handleLogout}>
            Logout
          </button>
        </div>
      </div>

      <ServerHealth runtime={dash.runtime} dbSizeBytes={dash.dbSizeBytes} />
      <UserAnalytics stats={dash.stats} registrationPoints={regPoints} />
      <Devices stats={dash.stats} />
      <Sessions
        stats={dash.stats}
        sessionPoints={sessPoints}
        tokenPoints={tokPoints}
        projects={projects}
      />
      <Commands stats={dash.stats} commandPoints={cmdPoints} />
      <PushNotifications stats={dash.stats} />
      <UsersTable />
      <Security />
    </div>
  )
}

export default function App() {
  const [loggedIn, setLoggedIn] = useState<boolean | null>(null)

  useEffect(() => {
    setOnUnauthorized(() => setLoggedIn(false))

    // Check if we have a valid session.
    api('/v1/admin/dashboard')
      .then(() => setLoggedIn(true))
      .catch(() => setLoggedIn(false))
  }, [])

  if (loggedIn === null) return null

  if (!loggedIn) {
    return <LoginScreen onLogin={() => setLoggedIn(true)} />
  }

  return <Dashboard onLogout={() => setLoggedIn(false)} />
}
