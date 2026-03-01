package model

import (
	"encoding/json"
	"time"
)

type SessionStatus string

const (
	StatusRunning           SessionStatus = "running"
	StatusIdle              SessionStatus = "idle"
	StatusWaitingInput      SessionStatus = "waiting_input"
	StatusWaitingPermission SessionStatus = "waiting_permission"
	StatusError             SessionStatus = "error"
	StatusCompleted         SessionStatus = "completed"
)

type Session struct {
	ID          string        `json:"id"`
	DeviceID    string        `json:"deviceId"`
	UserID      string        `json:"userId"`
	ProjectPath string        `json:"projectPath"`
	GitBranch   string        `json:"gitBranch"`
	CWD         string        `json:"cwd"`
	Status      SessionStatus `json:"status"`
	StartedAt   time.Time     `json:"startedAt"`
	UpdatedAt   time.Time     `json:"updatedAt"`
	TokensIn    int64         `json:"tokensIn"`
	TokensOut   int64         `json:"tokensOut"`
	TurnCount   int           `json:"turnCount"`
	ProjectID          string        `json:"projectId,omitempty"`
	Description        string        `json:"description"`
	EphemeralPublicKey string        `json:"ephemeralPublicKey,omitempty"`
}

type SessionEvent struct {
	ID        string          `json:"id"`
	SessionID string          `json:"sessionId"`
	DeviceID  string          `json:"deviceId"`
	EventType string          `json:"eventType"`
	Timestamp time.Time       `json:"timestamp"`
	Payload   json.RawMessage `json:"payload"`
	Content   json.RawMessage `json:"content,omitempty"`
	Seq       int             `json:"seq"`
	CreatedAt time.Time       `json:"createdAt"`
}
