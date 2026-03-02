import { createContext, useContext, useState, useEffect, useCallback, type ReactNode } from 'react'
import { api, adminLogout as doLogout, setOnUnauthorized } from '../api'
import { useAutoRefresh } from '../hooks/useAutoRefresh'
import type { DashboardResponse } from '../types'

interface AuthState {
  loggedIn: boolean | null
  setLoggedIn: (v: boolean) => void
  logout: () => void
  dashboard: DashboardResponse | null
  refreshDashboard: () => Promise<void>
}

const AuthContext = createContext<AuthState | null>(null)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [loggedIn, setLoggedIn] = useState<boolean | null>(null)
  const [dashboard, setDashboard] = useState<DashboardResponse | null>(null)

  const refreshDashboard = useCallback(async () => {
    try {
      const d = await api<DashboardResponse>('/v1/admin/dashboard')
      setDashboard(d)
      setLoggedIn(true)
    } catch {
      // If unauthorized, the api() onUnauthorized handler sets loggedIn=false
    }
  }, [])

  useEffect(() => {
    setOnUnauthorized(() => {
      setLoggedIn(false)
      setDashboard(null)
    })
    // Single initial call: checks auth AND gets dashboard data
    refreshDashboard()
  }, [refreshDashboard])

  // Auto-refresh only when logged in
  useAutoRefresh(loggedIn ? refreshDashboard : () => {})

  const logout = useCallback(() => {
    doLogout()
    setLoggedIn(false)
    setDashboard(null)
  }, [])

  return (
    <AuthContext.Provider value={{ loggedIn, setLoggedIn, logout, dashboard, refreshDashboard }}>
      {children}
    </AuthContext.Provider>
  )
}

export function useAuth() {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth must be used within AuthProvider')
  return ctx
}
