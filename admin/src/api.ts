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

export async function adminLogin(secret: string): Promise<{ status: string }> {
  const res = await fetch('/v1/admin/login', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ secret }),
  })
  const data = await parseJSON(res)
  if (!res.ok) {
    throw new Error(data.error || 'Login failed')
  }
  return data
}

export function adminLogout() {
  document.cookie = 'afk_admin_session=; path=/; max-age=0'
}
