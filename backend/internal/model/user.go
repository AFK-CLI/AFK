package model

import (
	"encoding/json"
	"time"
)

type User struct {
	ID                    string     `json:"id"`
	AppleUserID           string     `json:"appleUserId"`
	Email                 string     `json:"email"`
	DisplayName           string     `json:"displayName"`
	SubscriptionTier      string     `json:"subscriptionTier"`
	SubscriptionExpiresAt *time.Time `json:"subscriptionExpiresAt,omitempty"`
	CreatedAt             time.Time  `json:"createdAt"`
	UpdatedAt             time.Time  `json:"updatedAt"`
}

type Device struct {
	ID                    string    `json:"id"`
	UserID                string    `json:"userId"`
	Name                  string    `json:"name"`
	PublicKey             string    `json:"publicKey"`
	SystemInfo            string    `json:"systemInfo,omitempty"`
	EnrolledAt            time.Time `json:"enrolledAt"`
	LastSeenAt            time.Time `json:"lastSeenAt"`
	IsOnline              bool      `json:"isOnline"`
	IsRevoked             bool      `json:"isRevoked"`
	PrivacyMode           string    `json:"privacyMode"`
	KeyAgreementPublicKey string    `json:"keyAgreementPublicKey,omitempty"`
	KeyVersion            int       `json:"keyVersion"`
	Capabilities          json.RawMessage `json:"capabilities"`
}

type DeviceKey struct {
	ID        string  `json:"id"`
	DeviceID  string  `json:"deviceId"`
	KeyType   string  `json:"keyType"` // "key_agreement"
	PublicKey string  `json:"publicKey"`
	Version   int     `json:"version"`
	Active    bool    `json:"active"`
	CreatedAt string  `json:"createdAt"`
	RevokedAt *string `json:"revokedAt,omitempty"`
}
