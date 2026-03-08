import { useState } from 'react'
import { adminLogin, doPasskeyLogin } from '../api'
import { useAuth } from '../contexts/AuthContext'

export function LoginPage() {
  const { setLoggedIn } = useAuth()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [totpCode, setTotpCode] = useState('')
  const [totpRequired, setTotpRequired] = useState(false)
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)

  const doEmailLogin = async () => {
    setLoading(true)
    setError('')
    try {
      const res = await adminLogin(email, password, totpRequired ? totpCode : undefined)
      if (res.totpRequired) {
        setTotpRequired(true)
        setLoading(false)
        return
      }
      setLoggedIn(true)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Connection error')
    } finally {
      setLoading(false)
    }
  }

  const doPasskey = async () => {
    setLoading(true)
    setError('')
    try {
      await doPasskeyLogin()
      setLoggedIn(true)
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Passkey login failed')
    } finally {
      setLoading(false)
    }
  }

  const passkeyAvailable = !!window.PublicKeyCredential

  return (
    <div className="login-wrap">
      <div className="login-box">
        <h1>AFK Admin</h1>
        <p>{totpRequired ? 'Enter your authenticator code' : 'Sign in to continue'}</p>
        {error && <div className="login-error">{error}</div>}
        {!totpRequired ? (
          <>
            <input
              type="email"
              placeholder="Email"
              autoFocus
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              onKeyDown={(e) => e.key === 'Enter' && doEmailLogin()}
            />
            <input
              type="password"
              placeholder="Password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              onKeyDown={(e) => e.key === 'Enter' && doEmailLogin()}
            />
          </>
        ) : (
          <input
            type="text"
            placeholder="6-digit code"
            autoFocus
            inputMode="numeric"
            maxLength={6}
            value={totpCode}
            onChange={(e) => setTotpCode(e.target.value.replace(/\D/g, ''))}
            onKeyDown={(e) => e.key === 'Enter' && doEmailLogin()}
          />
        )}
        <button onClick={doEmailLogin} disabled={loading}>
          {loading ? 'Signing in...' : 'Sign In'}
        </button>
        {passkeyAvailable && !totpRequired && (
          <>
            <div className="login-divider"><span>or</span></div>
            <button className="passkey-btn" onClick={doPasskey} disabled={loading}>
              Sign in with Passkey
            </button>
          </>
        )}
      </div>
    </div>
  )
}
