let onUnauthorized: (() => void) | null = null

export function setOnUnauthorized(cb: () => void) {
  onUnauthorized = cb
}

async function parseJSON(res: Response) {
  const text = await res.text()
  try {
    return JSON.parse(text)
  } catch {
    throw new Error(text || `HTTP ${res.status}`)
  }
}

export async function api<T>(path: string, opts?: RequestInit): Promise<T> {
  const res = await fetch(path, opts)
  if (res.status === 401) {
    onUnauthorized?.()
    throw new Error('unauthorized')
  }
  if (!res.ok) {
    const data = await parseJSON(res)
    throw new Error(data.error || `HTTP ${res.status}`)
  }
  return parseJSON(res)
}

export async function apiPut<T>(path: string, body: unknown): Promise<T> {
  return api<T>(path, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
}

export async function apiDelete<T>(path: string, body?: unknown): Promise<T> {
  const opts: RequestInit = { method: 'DELETE' }
  if (body) {
    opts.headers = { 'Content-Type': 'application/json' }
    opts.body = JSON.stringify(body)
  }
  return api<T>(path, opts)
}

export async function apiPost<T>(path: string, body?: unknown): Promise<T> {
  const opts: RequestInit = { method: 'POST', headers: { 'Content-Type': 'application/json' } }
  if (body) opts.body = JSON.stringify(body)
  return api<T>(path, opts)
}

export async function adminLogin(email: string, password: string, totpCode?: string): Promise<{ status: string; totpRequired?: boolean }> {
  const body: Record<string, string> = { email, password }
  if (totpCode) body.totpCode = totpCode
  const res = await fetch('/v1/admin/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  const data = await parseJSON(res)
  if (!res.ok) {
    throw new Error(data.error || 'Login failed')
  }
  return data
}

export async function adminPasskeyLoginBegin(): Promise<{ publicKey: PublicKeyCredentialRequestOptions; sessionKey: string }> {
  const res = await fetch('/v1/admin/passkey/login/begin', { method: 'POST' })
  const data = await parseJSON(res)
  if (!res.ok) throw new Error(data.error || 'Passkey login failed')
  return data
}

export async function adminPasskeyLoginFinish(credential: PublicKeyCredential, sessionKey: string): Promise<{ status: string }> {
  const response = credential.response as AuthenticatorAssertionResponse
  const body = {
    sessionKey,
    id: credential.id,
    rawId: bufToBase64url(new Uint8Array(credential.rawId)),
    type: credential.type,
    response: {
      authenticatorData: bufToBase64url(new Uint8Array(response.authenticatorData)),
      clientDataJSON: bufToBase64url(new Uint8Array(response.clientDataJSON)),
      signature: bufToBase64url(new Uint8Array(response.signature)),
      userHandle: response.userHandle ? bufToBase64url(new Uint8Array(response.userHandle)) : undefined,
    },
  }
  const res = await fetch('/v1/admin/passkey/login/finish', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  const data = await parseJSON(res)
  if (!res.ok) throw new Error(data.error || 'Passkey login failed')
  return data
}

export function bufToBase64url(buf: Uint8Array): string {
  let s = ''
  for (const b of buf) s += String.fromCharCode(b)
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

export function base64urlToBuf(s: string): ArrayBuffer {
  const padded = s.replace(/-/g, '+').replace(/_/g, '/') + '=='.slice(0, (4 - (s.length % 4)) % 4)
  const raw = atob(padded)
  const buf = new Uint8Array(raw.length)
  for (let i = 0; i < raw.length; i++) buf[i] = raw.charCodeAt(i)
  return buf.buffer
}

export async function doPasskeyLogin(): Promise<void> {
  const { publicKey, sessionKey } = await adminPasskeyLoginBegin()

  // Convert base64url fields to ArrayBuffers for WebAuthn API.
  const opts: PublicKeyCredentialRequestOptions = {
    ...publicKey,
    challenge: base64urlToBuf(publicKey.challenge as unknown as string),
  }
  if (publicKey.allowCredentials) {
    opts.allowCredentials = publicKey.allowCredentials.map((c: any) => ({
      ...c,
      id: base64urlToBuf(c.id as unknown as string),
    }))
  }

  const credential = await navigator.credentials.get({ publicKey: opts }) as PublicKeyCredential
  if (!credential) throw new Error('No credential returned')

  await adminPasskeyLoginFinish(credential, sessionKey)
}

export function adminLogout() {
  document.cookie = 'afk_admin_session=; path=/; max-age=0'
}

export interface AdminProfile {
  id: string
  email: string
  totpEnabled: boolean
  passkeyCount: number
  passkeys: { id: string; friendlyName: string; createdAt: string; lastUsedAt: string }[]
  createdAt: string
}

export async function getAdminProfile(): Promise<AdminProfile> {
  return api<AdminProfile>('/v1/admin/me')
}

export async function adminTOTPSetup(): Promise<{ otpauthURI: string; secret: string }> {
  return apiPost<{ otpauthURI: string; secret: string }>('/v1/admin/totp/setup')
}

export async function adminTOTPVerify(code: string): Promise<{ status: string }> {
  return apiPost<{ status: string }>('/v1/admin/totp/verify', { code })
}

export async function adminPasskeyRegisterBegin(): Promise<{ publicKey: PublicKeyCredentialCreationOptions; sessionKey: string }> {
  const res = await fetch('/v1/admin/passkey/register/begin', { method: 'POST' })
  const data = await parseJSON(res)
  if (!res.ok) throw new Error(data.error || 'Passkey registration failed')
  return data
}

export async function adminPasskeyRegisterFinish(credential: PublicKeyCredential, sessionKey: string): Promise<{ status: string }> {
  const response = credential.response as AuthenticatorAttestationResponse
  const body = {
    sessionKey,
    id: credential.id,
    rawId: bufToBase64url(new Uint8Array(credential.rawId)),
    type: credential.type,
    response: {
      attestationObject: bufToBase64url(new Uint8Array(response.attestationObject)),
      clientDataJSON: bufToBase64url(new Uint8Array(response.clientDataJSON)),
    },
  }
  const res = await fetch('/v1/admin/passkey/register/finish', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  const data = await parseJSON(res)
  if (!res.ok) throw new Error(data.error || 'Passkey registration failed')
  return data
}

export async function doPasskeyRegister(): Promise<void> {
  const { publicKey, sessionKey } = await adminPasskeyRegisterBegin()

  const opts: PublicKeyCredentialCreationOptions = {
    ...publicKey,
    challenge: base64urlToBuf(publicKey.challenge as unknown as string),
    user: {
      ...publicKey.user,
      id: base64urlToBuf((publicKey.user as any).id as unknown as string),
    },
  }
  if (publicKey.excludeCredentials) {
    opts.excludeCredentials = (publicKey.excludeCredentials as any[]).map((c: any) => ({
      ...c,
      id: base64urlToBuf(c.id as unknown as string),
    }))
  }

  const credential = await navigator.credentials.create({ publicKey: opts }) as PublicKeyCredential
  if (!credential) throw new Error('No credential returned')

  await adminPasskeyRegisterFinish(credential, sessionKey)
}
