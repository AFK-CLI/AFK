import { useState, useEffect, useRef } from 'react'
import QRCode from 'qrcode'
import {
  getAdminProfile,
  adminTOTPSetup,
  adminTOTPVerify,
  doPasskeyRegister,
  type AdminProfile,
} from '../api'
import { useAuth } from '../contexts/AuthContext'
import { useToast } from '../contexts/ToastContext'

export function ProfilePage() {
  const { logout } = useAuth()
  const { showToast } = useToast()
  const [profile, setProfile] = useState<AdminProfile | null>(null)
  const [loading, setLoading] = useState(true)

  // Passkey state
  const [registeringPasskey, setRegisteringPasskey] = useState(false)

  // TOTP state
  const qrCanvasRef = useRef<HTMLCanvasElement>(null)
  const [totpSetupData, setTotpSetupData] = useState<{ otpauthURI: string; secret: string } | null>(null)
  const [totpCode, setTotpCode] = useState('')
  const [totpLoading, setTotpLoading] = useState(false)

  const loadProfile = async () => {
    try {
      const p = await getAdminProfile()
      setProfile(p)
    } catch {
      showToast('Failed to load profile', 'error')
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    loadProfile()
  }, [])

  useEffect(() => {
    if (totpSetupData && qrCanvasRef.current) {
      QRCode.toCanvas(qrCanvasRef.current, totpSetupData.otpauthURI, {
        width: 200,
        margin: 2,
        color: { dark: '#1a1a2e', light: '#ffffff' },
      })
    }
  }, [totpSetupData])

  const handleRegisterPasskey = async () => {
    setRegisteringPasskey(true)
    try {
      await doPasskeyRegister()
      showToast('Passkey registered successfully')
      await loadProfile()
    } catch (e) {
      showToast(e instanceof Error ? e.message : 'Passkey registration failed', 'error')
    } finally {
      setRegisteringPasskey(false)
    }
  }

  const handleTOTPSetup = async () => {
    setTotpLoading(true)
    try {
      const data = await adminTOTPSetup()
      setTotpSetupData(data)
    } catch (e) {
      showToast(e instanceof Error ? e.message : 'TOTP setup failed', 'error')
    } finally {
      setTotpLoading(false)
    }
  }

  const handleTOTPVerify = async () => {
    if (totpCode.length !== 6) return
    setTotpLoading(true)
    try {
      await adminTOTPVerify(totpCode)
      showToast('MFA enabled successfully')
      setTotpSetupData(null)
      setTotpCode('')
      await loadProfile()
    } catch (e) {
      showToast(e instanceof Error ? e.message : 'Verification failed', 'error')
    } finally {
      setTotpLoading(false)
    }
  }

  if (loading) return <div className="page-loading">Loading...</div>
  if (!profile) return <div className="page-loading">Failed to load profile</div>

  const passkeyAvailable = !!window.PublicKeyCredential

  return (
    <div>
      <div className="page-header">
        <div>
          <h1>Profile</h1>
          <div className="page-subtitle">Admin account settings</div>
        </div>
      </div>

      {/* Account Info */}
      <div className="section">
        <h2>Account</h2>
        <div className="profile-card">
          <div className="profile-row">
            <span className="profile-label">Email</span>
            <span className="profile-value">{profile.email}</span>
          </div>
          <div className="profile-row">
            <span className="profile-label">Account ID</span>
            <span className="profile-value profile-mono">{profile.id}</span>
          </div>
          <div className="profile-row">
            <span className="profile-label">Created</span>
            <span className="profile-value">{new Date(profile.createdAt).toLocaleDateString()}</span>
          </div>
        </div>
      </div>

      {/* Passkeys */}
      <div className="section">
        <h2>Passkeys</h2>
        <div className="profile-card">
          {profile.passkeys.length === 0 ? (
            <p className="profile-empty">No passkeys registered. Add one for passwordless login.</p>
          ) : (
            <div className="profile-passkey-list">
              {profile.passkeys.map((pk) => (
                <div key={pk.id} className="profile-passkey-item">
                  <div className="profile-passkey-name">{pk.friendlyName || 'Passkey'}</div>
                  <div className="profile-passkey-meta">
                    Added {new Date(pk.createdAt).toLocaleDateString()}
                    {pk.lastUsedAt && pk.lastUsedAt !== '0001-01-01T00:00:00Z' && (
                      <> &middot; Last used {new Date(pk.lastUsedAt).toLocaleDateString()}</>
                    )}
                  </div>
                </div>
              ))}
            </div>
          )}
          {passkeyAvailable && (
            <button
              className="btn-sm btn-primary profile-action-btn"
              onClick={handleRegisterPasskey}
              disabled={registeringPasskey}
            >
              {registeringPasskey ? 'Registering...' : 'Register New Passkey'}
            </button>
          )}
          {!passkeyAvailable && (
            <p className="profile-empty">Passkeys are not supported in this browser.</p>
          )}
        </div>
      </div>

      {/* MFA / TOTP */}
      <div className="section">
        <h2>Multi-Factor Authentication</h2>
        <div className="profile-card">
          {profile.totpEnabled ? (
            <div className="profile-mfa-status">
              <span className="badge badge-green">Enabled</span>
              <span className="profile-mfa-text">
                Authenticator app is configured. You will be prompted for a code on each login.
              </span>
            </div>
          ) : totpSetupData ? (
            <div className="profile-totp-setup">
              <p className="profile-totp-instruction">
                Scan this QR code with your authenticator app, or enter the secret manually.
              </p>
              <div className="profile-qr-wrap">
                <canvas ref={qrCanvasRef} className="profile-qr-img" />
              </div>
              <div className="profile-totp-secret">
                <span className="profile-label">Secret</span>
                <code className="profile-secret-code">{totpSetupData.secret}</code>
              </div>
              <div className="profile-totp-verify">
                <input
                  type="text"
                  placeholder="6-digit code"
                  inputMode="numeric"
                  maxLength={6}
                  value={totpCode}
                  onChange={(e) => setTotpCode(e.target.value.replace(/\D/g, ''))}
                  onKeyDown={(e) => e.key === 'Enter' && handleTOTPVerify()}
                  className="profile-totp-input"
                />
                <button
                  className="btn-sm btn-primary"
                  onClick={handleTOTPVerify}
                  disabled={totpLoading || totpCode.length !== 6}
                >
                  {totpLoading ? 'Verifying...' : 'Verify & Enable'}
                </button>
              </div>
            </div>
          ) : (
            <>
              <p className="profile-empty">
                MFA is not enabled. Add an authenticator app for extra security.
              </p>
              <button
                className="btn-sm btn-primary profile-action-btn"
                onClick={handleTOTPSetup}
                disabled={totpLoading}
              >
                {totpLoading ? 'Setting up...' : 'Enable MFA'}
              </button>
            </>
          )}
        </div>
      </div>

      {/* Logout */}
      <div className="section">
        <button className="btn-sm btn-danger" onClick={logout}>
          Logout
        </button>
      </div>
    </div>
  )
}
