import { useState, useEffect } from 'react'
import { api, apiPut } from '../api'
import { PageHeader } from '../components/PageHeader'

export function SettingsPage() {
  const [settings, setSettings] = useState<Record<string, string>>({})
  const [testflightUrl, setTestflightUrl] = useState('')
  const [saving, setSaving] = useState(false)
  const [msg, setMsg] = useState<{ type: 'ok' | 'err'; text: string } | null>(null)

  useEffect(() => {
    api<{ settings: Record<string, string> }>('/v1/admin/settings')
      .then((r) => {
        setSettings(r.settings ?? {})
        setTestflightUrl(r.settings?.testflight_url ?? '')
      })
      .catch(() => {})
  }, [])

  async function save() {
    setSaving(true)
    setMsg(null)
    try {
      await apiPut('/v1/admin/settings', { key: 'testflight_url', value: testflightUrl.trim() })
      setMsg({ type: 'ok', text: 'Saved' })
      setSettings((s) => ({ ...s, testflight_url: testflightUrl.trim() }))
    } catch (e: any) {
      setMsg({ type: 'err', text: e.message || 'Failed to save' })
    } finally {
      setSaving(false)
    }
  }

  const changed = testflightUrl.trim() !== (settings.testflight_url ?? '')

  return (
    <div>
      <PageHeader title="Settings" subtitle="Site configuration" />
      <div style={{ maxWidth: 600 }}>
        <div className="card" style={{ padding: 24 }}>
          <h3 style={{ marginBottom: 4, fontSize: '1rem' }}>TestFlight URL</h3>
          <p style={{ color: 'var(--text-dim)', fontSize: '0.85rem', marginBottom: 16 }}>
            Public TestFlight invite link shown on the landing page. Leave empty to hide the button.
          </p>
          <div style={{ display: 'flex', gap: 8 }}>
            <input
              type="url"
              value={testflightUrl}
              onChange={(e) => { setTestflightUrl(e.target.value); setMsg(null) }}
              placeholder="https://testflight.apple.com/join/..."
              style={{
                flex: 1,
                padding: '8px 12px',
                borderRadius: 6,
                border: '1px solid var(--border)',
                background: 'var(--bg-card)',
                color: 'var(--text)',
                fontSize: '0.9rem',
              }}
            />
            <button className="btn-sm" onClick={save} disabled={saving || !changed}>
              {saving ? 'Saving...' : 'Save'}
            </button>
          </div>
          {msg && (
            <p style={{ marginTop: 8, fontSize: '0.85rem', color: msg.type === 'ok' ? 'var(--green)' : 'var(--red)' }}>
              {msg.text}
            </p>
          )}
        </div>
      </div>
    </div>
  )
}
