package model

import "encoding/json"

// Auth

type AppleAuthRequest struct {
	IdentityToken string `json:"identityToken"`
}

type AuthResponse struct {
	AccessToken  string `json:"accessToken"`
	RefreshToken string `json:"refreshToken"`
	ExpiresAt    int64  `json:"expiresAt"`
	User         *User  `json:"user"`
}

type RefreshRequest struct {
	RefreshToken string `json:"refreshToken"`
}

type EmailRegisterRequest struct {
	Email       string `json:"email"`
	Password    string `json:"password"`
	DisplayName string `json:"displayName,omitempty"`
}

type EmailLoginRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

type LogoutRequest struct {
	RefreshToken string `json:"refreshToken"`
}

// Devices

type EnrollDeviceRequest struct {
	Name                  string   `json:"name"`
	PublicKey             string   `json:"publicKey"`
	SystemInfo            string   `json:"systemInfo"`
	KeyAgreementPublicKey string   `json:"keyAgreementPublicKey,omitempty"`
	DeviceID              string   `json:"deviceId,omitempty"`
	Capabilities          []string `json:"capabilities,omitempty"`
}

// WebSocket envelope

type WSMessage struct {
	Type      string          `json:"type"`
	Payload   json.RawMessage `json:"payload"`
	Timestamp int64           `json:"ts"`
}

// Agent payloads

type AgentHeartbeat struct {
	DeviceID       string   `json:"deviceId"`
	Uptime         int64    `json:"uptime"`
	ActiveSessions []string `json:"activeSessions"`
}

type AgentSessionUpdate struct {
	SessionID          string `json:"sessionId"`
	ProjectPath        string `json:"projectPath"`
	GitBranch          string `json:"gitBranch"`
	CWD                string `json:"cwd"`
	Status             string `json:"status"`
	TokensIn           int64  `json:"tokensIn"`
	TokensOut          int64  `json:"tokensOut"`
	TurnCount          int    `json:"turnCount"`
	Description        string `json:"description"`
	EphemeralPublicKey string `json:"ephemeralPublicKey,omitempty"`
}

type AgentUsageUpdate struct {
	DeviceID               string  `json:"deviceId"`
	SessionPercentage      float64 `json:"sessionPercentage"`
	SessionResetTime       string  `json:"sessionResetTime"`
	WeeklyPercentage       float64 `json:"weeklyPercentage"`
	WeeklyResetTime        string  `json:"weeklyResetTime"`
	OpusWeeklyPercentage   float64 `json:"opusWeeklyPercentage"`
	SonnetWeeklyPercentage float64 `json:"sonnetWeeklyPercentage"`
	SonnetWeeklyResetTime  string  `json:"sonnetWeeklyResetTime,omitempty"`
	SubscriptionType       string  `json:"subscriptionType"`
	LastUpdated            string  `json:"lastUpdated"`
}

type AgentSessionEvent struct {
	SessionID string          `json:"sessionId"`
	EventType string          `json:"eventType"`
	Data      json.RawMessage `json:"data"`
	Content   json.RawMessage `json:"content,omitempty"`
	Seq       int             `json:"seq,omitempty"`
}

type AgentSessionMetrics struct {
	SessionID           string  `json:"sessionId"`
	Model               string  `json:"model"`
	CostUsd             float64 `json:"costUsd"`
	InputTokens         int64   `json:"inputTokens"`
	OutputTokens        int64   `json:"outputTokens"`
	CacheReadTokens     int64   `json:"cacheReadTokens"`
	CacheCreationTokens int64   `json:"cacheCreationTokens"`
	DurationMs          int64   `json:"durationMs"`
}

// iOS payloads

type AppSubscribe struct {
	SessionIDs []string `json:"sessionIds"`
}

type SessionUpdateNotification struct {
	Session    *Session `json:"session"`
	DeviceName string   `json:"deviceName"`
}

type SessionEventNotification struct {
	ID         string          `json:"id"`
	Seq        int             `json:"seq"`
	SessionID  string          `json:"sessionId"`
	EventType  string          `json:"eventType"`
	Data       json.RawMessage `json:"data"`
	Content    json.RawMessage `json:"content,omitempty"`
	DeviceName string          `json:"deviceName"`
}

type DeviceStatusNotification struct {
	DeviceID   string `json:"deviceId"`
	DeviceName string `json:"deviceName"`
	IsOnline   bool   `json:"isOnline"`
}

// Permission approval

type PermissionRequest struct {
	SessionID string            `json:"sessionId"`
	ToolName  string            `json:"toolName"`
	ToolInput map[string]string `json:"toolInput"`
	ToolUseID string            `json:"toolUseId"`
	Nonce     string            `json:"nonce"`
	ExpiresAt int64             `json:"expiresAt"`
	DeviceID  string            `json:"deviceId"`
	Challenge string            `json:"challenge,omitempty"`
}

type AppPermissionResponse struct {
	Nonce             string `json:"nonce"`
	Action            string `json:"action"`
	Signature         string `json:"signature"`
	FallbackSignature string `json:"fallbackSignature,omitempty"`
}

type AppPermissionMode struct {
	DeviceID string `json:"deviceId"`
	Mode     string `json:"mode"` // "ask", "acceptEdits", "plan", "autoApprove"
}

type AppAgentControl struct {
	DeviceID       string `json:"deviceId"`
	RemoteApproval *bool  `json:"remoteApproval,omitempty"`
	AutoPlanExit   *bool  `json:"autoPlanExit,omitempty"`
}

type AgentControlState struct {
	DeviceID       string `json:"deviceId"`
	RemoteApproval bool   `json:"remoteApproval"`
	AutoPlanExit   bool   `json:"autoPlanExit"`
}

// Privacy & Audit

type AuditLogEntry struct {
	ID          string `json:"id"`
	UserID      string `json:"userId"`
	DeviceID    string `json:"deviceId,omitempty"`
	Action      string `json:"action"`
	Details     string `json:"details"`
	ContentHash string `json:"contentHash,omitempty"`
	IPAddress   string `json:"ipAddress,omitempty"`
	CreatedAt   string `json:"createdAt"`
}

type SetPrivacyModeRequest struct {
	PrivacyMode string `json:"privacyMode"` // "telemetry_only", "relay_only", "encrypted"
}

type SetProjectPrivacyRequest struct {
	ProjectPathHash string `json:"projectPathHash"`
	PrivacyMode     string `json:"privacyMode"`
}

// Command continue

type ImageAttachment struct {
	MediaType string `json:"mediaType"`
	Data      string `json:"data"`
}

type ContinueRequest struct {
	Prompt          string            `json:"prompt"`
	PromptEncrypted string            `json:"promptEncrypted,omitempty"`
	Images          []ImageAttachment `json:"images,omitempty"`
	ImagesEncrypted []ImageAttachment `json:"imagesEncrypted,omitempty"`
	Nonce           string            `json:"nonce"`
	ExpiresAt       int64             `json:"expiresAt"`
}

type Command struct {
	ID              string `json:"id"`
	SessionID       string `json:"sessionId"`
	UserID          string `json:"userId"`
	DeviceID        string `json:"deviceId"`
	PromptHash      string `json:"promptHash"`
	PromptEncrypted string `json:"promptEncrypted,omitempty"`
	Nonce           string `json:"nonce"`
	Status          string `json:"status"`
	CreatedAt       string `json:"createdAt"`
	UpdatedAt       string `json:"updatedAt"`
	ExpiresAt       string `json:"expiresAt"`
}

// Command streaming payloads (from agent)

type CommandAck struct {
	CommandID string `json:"commandId"`
	SessionID string `json:"sessionId"`
}

type CommandChunk struct {
	CommandID string `json:"commandId"`
	SessionID string `json:"sessionId"`
	Text      string `json:"text"`
	Seq       int    `json:"seq"`
}

type CommandDone struct {
	CommandID    string  `json:"commandId"`
	SessionID    string  `json:"sessionId"`
	DurationMs   int     `json:"durationMs,omitempty"`
	CostUsd      float64 `json:"costUsd,omitempty"`
	NewSessionID string  `json:"newSessionId,omitempty"`
}

type CommandFailed struct {
	CommandID string `json:"commandId"`
	SessionID string `json:"sessionId"`
	Error     string `json:"error"`
}

// Push tokens

type PushToken struct {
	ID          string `json:"id"`
	UserID      string `json:"userId"`
	DeviceToken string `json:"deviceToken"`
	Platform    string `json:"platform"`
	BundleID    string `json:"bundleId"`
	CreatedAt   string `json:"createdAt"`
	UpdatedAt   string `json:"updatedAt"`
}

type RegisterPushTokenRequest struct {
	DeviceToken string `json:"deviceToken"`
	Platform    string `json:"platform"`
	BundleID    string `json:"bundleId"`
}

// Notification preferences

type NotificationPrefs struct {
	UserID             string `json:"userId,omitempty"`
	PermissionRequests bool   `json:"permissionRequests"`
	SessionErrors      bool   `json:"sessionErrors"`
	SessionCompletions bool   `json:"sessionCompletions"`
	AskUser            bool   `json:"askUser"`
	SessionActivity    bool   `json:"sessionActivity"`
	QuietHoursStart    string `json:"quietHoursStart,omitempty"`
	QuietHoursEnd      string `json:"quietHoursEnd,omitempty"`
}

// Cancel command

type CancelRequest struct {
	CommandID string `json:"commandId"`
}

type CommandCancelled struct {
	CommandID string `json:"commandId"`
	SessionID string `json:"sessionId"`
}

// Device key rotation notification (broadcast to all user's iOS clients)

type DeviceKeyRotated struct {
	DeviceID   string `json:"deviceId"`
	KeyVersion int    `json:"keyVersion"`
	PublicKey  string `json:"publicKey"`
}

// Plan restart (iOS → Agent via backend)

type AppPlanRestart struct {
	SessionID      string `json:"sessionId"`
	DeviceID       string `json:"deviceId"`
	PermissionMode string `json:"permissionMode"`
	Feedback       string `json:"feedback,omitempty"`
}

// Server -> Agent command payload

type ServerCommand struct {
	CommandID       string            `json:"commandId"`
	SessionID       string            `json:"sessionId"`
	Prompt          string            `json:"prompt"`
	PromptEncrypted string            `json:"promptEncrypted,omitempty"`
	Images          []ImageAttachment `json:"images,omitempty"`
	ImagesEncrypted []ImageAttachment `json:"imagesEncrypted,omitempty"`
	PromptHash      string            `json:"promptHash"`
	Nonce           string            `json:"nonce"`
	ExpiresAt       int64             `json:"expiresAt"`
	Signature       string            `json:"signature"`
}

// New Chat

type NewChatRequest struct {
	Prompt          string `json:"prompt"`
	PromptEncrypted string `json:"promptEncrypted,omitempty"`
	ProjectPath     string `json:"projectPath"`
	DeviceID        string `json:"deviceId"`
	UseWorktree     bool   `json:"useWorktree"`
	WorktreeName    string `json:"worktreeName,omitempty"`
	PermissionMode  string `json:"permissionMode,omitempty"`
	Nonce           string `json:"nonce"`
	ExpiresAt       int64  `json:"expiresAt"`
}

type ServerNewCommand struct {
	CommandID       string `json:"commandId"`
	ProjectPath     string `json:"projectPath"`
	Prompt          string `json:"prompt"`
	PromptEncrypted string `json:"promptEncrypted,omitempty"`
	PromptHash      string `json:"promptHash"`
	UseWorktree     bool   `json:"useWorktree"`
	WorktreeName    string `json:"worktreeName,omitempty"`
	PermissionMode  string `json:"permissionMode,omitempty"`
	TodoText        string `json:"todoText,omitempty"`
	Nonce           string `json:"nonce"`
	ExpiresAt       int64  `json:"expiresAt"`
	Signature       string `json:"signature"`
}

// Tasks

type Task struct {
	ID             string `json:"id"`
	UserID         string `json:"userId,omitempty"`
	SessionID      string `json:"sessionId,omitempty"`
	ProjectID      string `json:"projectId,omitempty"`
	Source         string `json:"source"`
	SessionLocalID string `json:"sessionLocalId,omitempty"`
	Subject        string `json:"subject"`
	Description    string `json:"description"`
	Status         string `json:"status"`
	ActiveForm     string `json:"activeForm,omitempty"`
	CreatedAt      string `json:"createdAt"`
	UpdatedAt      string `json:"updatedAt"`
	ProjectName    string `json:"projectName,omitempty"`
}

type CreateTaskRequest struct {
	Subject     string `json:"subject"`
	Description string `json:"description"`
	ProjectID   string `json:"projectId,omitempty"`
}

type UpdateTaskRequest struct {
	Subject     *string `json:"subject,omitempty"`
	Description *string `json:"description,omitempty"`
	Status      *string `json:"status,omitempty"`
}

type TaskNotification struct {
	Task *Task `json:"task"`
}

// Todos

type TodoItem struct {
	Text       string `json:"text"`
	Checked    bool   `json:"checked"`
	InProgress bool   `json:"inProgress"`
	Line       int    `json:"line"`
}

type TodoSync struct {
	ProjectPath string     `json:"projectPath"`
	ContentHash string     `json:"contentHash"`
	RawContent  string     `json:"rawContent"`
	Items       []TodoItem `json:"items"`
}

type TodoState struct {
	ProjectID   string     `json:"projectId"`
	ProjectPath string     `json:"projectPath"`
	ProjectName string     `json:"projectName,omitempty"`
	RawContent  string     `json:"rawContent"`
	Items       []TodoItem `json:"items"`
	UpdatedAt   string     `json:"updatedAt"`
}

type TodoAppendRequest struct {
	ProjectID string `json:"projectId"`
	Text      string `json:"text"`
}

type TodoStartSessionRequest struct {
	ProjectID      string `json:"projectId"`
	DeviceID       string `json:"deviceId"`
	TodoText       string `json:"todoText"`
	UseWorktree    bool   `json:"useWorktree"`
	PermissionMode string `json:"permissionMode,omitempty"`
}

type TodoToggleRequest struct {
	ProjectID string `json:"projectId"`
	Line      int    `json:"line"`
	Checked   bool   `json:"checked"`
}

// Server -> Agent todo append payload
type ServerTodoAppend struct {
	ProjectPath string `json:"projectPath"`
	Text        string `json:"text"`
}

// Server -> Agent todo toggle payload
type ServerTodoToggle struct {
	ProjectPath string `json:"projectPath"`
	Line        int    `json:"line"`
	Checked     bool   `json:"checked"`
}

// App Logs

type AppLog struct {
	ID        string `json:"id"`
	UserID    string `json:"userId"`
	DeviceID  string `json:"deviceId"`
	Source    string `json:"source"`
	Level     string `json:"level"`
	Subsystem string `json:"subsystem"`
	Message   string `json:"message"`
	Metadata  string `json:"metadata"`
	CreatedAt string `json:"createdAt"`
}

type AppLogEntry struct {
	DeviceID  string            `json:"deviceId"`
	Source    string            `json:"source"`
	Level     string            `json:"level"`
	Subsystem string            `json:"subsystem"`
	Message   string            `json:"message"`
	Metadata  map[string]string `json:"metadata,omitempty"`
}

type BatchLogRequest struct {
	Entries []AppLogEntry `json:"entries"`
}

// Feedback

type Feedback struct {
	ID         string `json:"id"`
	UserID     string `json:"userId"`
	DeviceID   string `json:"deviceId"`
	Category   string `json:"category"`
	Message    string `json:"message"`
	AppVersion string `json:"appVersion"`
	Platform   string `json:"platform"`
	CreatedAt  string `json:"createdAt"`
}

type CreateFeedbackRequest struct {
	DeviceID   string `json:"deviceId"`
	Category   string `json:"category"`
	Message    string `json:"message"`
	AppVersion string `json:"appVersion"`
	Platform   string `json:"platform"`
}
