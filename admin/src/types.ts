export interface AdminStats {
  totalUsers: number
  registeredToday: number
  registeredThisWeek: number
  dau: number
  wau: number
  mau: number
  usersByTier: Record<string, number>
  usersByAuth: Record<string, number>

  totalDevices: number
  onlineDevices: number
  offlineDevices: number
  e2eeDevices: number
  staleDevices: number
  byPrivacyMode: Record<string, number>

  totalSessions: number
  sessionsByStatus: Record<string, number>
  avgDuration: number
  avgTurnCount: number
  totalTokensIn: number
  totalTokensOut: number

  commandsByStatus: Record<string, number>

  totalPushTokens: number
  pushByPlatform: Record<string, number>
}

export interface RuntimeMetrics {
  version: string
  uptime: number
  agentConnections: number
  iosConnections: number
  requestsTotal: number
  requestErrors: number
  wsMessagesReceived: number
  wsMessagesSent: number
  wsDroppedMessages: number
  rateLimitHits: number
}

export interface DashboardResponse {
  stats: AdminStats
  runtime: RuntimeMetrics
  dbSizeBytes: number
}

export interface TimeseriesPoint {
  date: string
  count: number
}

export interface TokenTimeseriesPoint {
  date: string
  tokensIn: number
  tokensOut: number
}

export interface AdminUser {
  id: string
  email: string
  displayName: string
  subscriptionTier: string
  authMethod: string
  deviceCount: number
  sessionCount: number
  createdAt: string
}

export interface AuditEntry {
  id: string
  userId: string
  deviceId: string
  action: string
  details: string
  ipAddress: string
  createdAt: string
  userEmail: string
}

export interface LoginAttempt {
  email: string
  attemptedAt: string
  success: boolean
  ipAddress: string
}

export interface LoginAttemptsResponse {
  attempts: LoginAttempt[]
  total: number
  failedLastHour: number
  failedLast24Hours: number
}

export interface AdminProject {
  id: string
  userId: string
  name: string
  sessionCount: number
}

export interface StaleDevice {
  id: string
  userId: string
  name: string
  lastSeenAt: string
  isRevoked: boolean
}

export interface AdminDevice {
  id: string
  userId: string
  userEmail: string
  name: string
  platform: string
  isOnline: boolean
  isRevoked: boolean
  privacyMode: string
  e2eeEnabled: boolean
  lastSeenAt: string
  createdAt: string
}

export interface AdminSession {
  id: string
  userId: string
  userEmail: string
  deviceId: string
  projectName: string
  gitBranch: string
  status: string
  startedAt: string
  updatedAt: string
  tokensIn: number
  tokensOut: number
  turnCount: number
  description: string
}

export interface AdminCommand {
  id: string
  sessionId: string
  userId: string
  userEmail: string
  type: string
  status: string
  prompt: string
  createdAt: string
  updatedAt: string
}

export interface AdminUserDetail {
  user: AdminUser
  devices: AdminDevice[]
  recentSessions: AdminSession[]
}

export interface AdminSessionDetailResponse {
  session: AdminSession
  commands: AdminCommand[]
}
