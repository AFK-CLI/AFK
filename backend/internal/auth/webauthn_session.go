package auth

import (
	"crypto/rand"
	"encoding/hex"
	"log/slog"
	"sync"
	"time"

	"github.com/go-webauthn/webauthn/webauthn"
)

const (
	webauthnSessionTTL      = 5 * time.Minute
	webauthnCleanupInterval = 60 * time.Second
)

// WebAuthnSessionStore is an in-memory store for WebAuthn challenge sessions.
type WebAuthnSessionStore struct {
	mu       sync.Mutex
	sessions map[string]*webauthnSession
}

type webauthnSession struct {
	Data      *webauthn.SessionData
	CreatedAt time.Time
}

func NewWebAuthnSessionStore() *WebAuthnSessionStore {
	return &WebAuthnSessionStore{
		sessions: make(map[string]*webauthnSession),
	}
}

// Save stores a session and returns a session key.
func (s *WebAuthnSessionStore) Save(data *webauthn.SessionData) string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic("crypto/rand.Read failed: " + err.Error())
	}
	key := hex.EncodeToString(b)

	s.mu.Lock()
	defer s.mu.Unlock()
	s.sessions[key] = &webauthnSession{
		Data:      data,
		CreatedAt: time.Now(),
	}
	return key
}

// Get retrieves and removes a session (single-use).
func (s *WebAuthnSessionStore) Get(key string) (*webauthn.SessionData, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()

	sess, ok := s.sessions[key]
	if !ok {
		return nil, false
	}
	delete(s.sessions, key)

	if time.Since(sess.CreatedAt) > webauthnSessionTTL {
		return nil, false
	}
	return sess.Data, true
}

// StartCleanup prunes expired sessions periodically.
func (s *WebAuthnSessionStore) StartCleanup(stop <-chan struct{}) {
	go func() {
		ticker := time.NewTicker(webauthnCleanupInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				s.cleanup()
			case <-stop:
				return
			}
		}
	}()
}

func (s *WebAuthnSessionStore) cleanup() {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	pruned := 0
	for key, sess := range s.sessions {
		if now.Sub(sess.CreatedAt) > webauthnSessionTTL {
			delete(s.sessions, key)
			pruned++
		}
	}
	if pruned > 0 {
		slog.Info("pruned expired webauthn sessions", "count", pruned)
	}
}
