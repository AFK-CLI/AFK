import { useState } from 'react'
import { adminLogin } from '../api'
import { useAuth } from '../contexts/AuthContext'

export function LoginPage() {
  const { setLoggedIn } = useAuth()
  const [secret, setSecret] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)

  const doLogin = async () => {
    setLoading(true)
    setError('')
    try {
      await adminLogin(secret)
      setLoggedIn(true)
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
