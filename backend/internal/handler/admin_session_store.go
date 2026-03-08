package handler

import (
	"crypto/rand"
	"encoding/hex"
	"sync"
	"time"
)

const (
	adminSessionMaxLifetime = 2 * time.Hour
	adminSessionCleanupFreq = 5 * time.Minute
)

type adminSession struct {
	AdminUserID string
	UserIP      string
	CreatedAt   time.Time
	ExpiresAt   time.Time
}

// AdminSessionStore provides server-side session management for the admin panel.
// Sessions are stored in-memory with IP binding and a 2-hour max lifetime.
type AdminSessionStore struct {
	mu       sync.Mutex
	sessions map[string]*adminSession
	stop     chan struct{}
}

// NewAdminSessionStore creates a new in-memory session store.
func NewAdminSessionStore() *AdminSessionStore {
	s := &AdminSessionStore{
		sessions: make(map[string]*adminSession),
		stop:     make(chan struct{}),
	}
	go s.cleanupLoop()
	return s
}

// Create generates a new cryptographic session ID bound to the client IP and admin user.
func (s *AdminSessionStore) Create(adminUserID, clientIP string) (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	sessionID := hex.EncodeToString(b)

	now := time.Now()
	s.mu.Lock()
	s.sessions[sessionID] = &adminSession{
		AdminUserID: adminUserID,
		UserIP:      clientIP,
		CreatedAt:   now,
		ExpiresAt:   now.Add(adminSessionMaxLifetime),
	}
	s.mu.Unlock()

	return sessionID, nil
}

// ValidateAndGetAdminID checks that a session ID exists, is not expired, matches the
// client IP, and returns the associated admin user ID.
func (s *AdminSessionStore) ValidateAndGetAdminID(sessionID, clientIP string) (string, bool) {
	s.mu.Lock()
	sess, ok := s.sessions[sessionID]
	s.mu.Unlock()

	if !ok {
		return "", false
	}
	if time.Now().After(sess.ExpiresAt) {
		s.Revoke(sessionID)
		return "", false
	}
	if sess.UserIP != clientIP {
		return "", false
	}
	return sess.AdminUserID, true
}

// Validate checks that a session ID exists, is not expired, and matches the client IP.
func (s *AdminSessionStore) Validate(sessionID, clientIP string) bool {
	s.mu.Lock()
	sess, ok := s.sessions[sessionID]
	s.mu.Unlock()

	if !ok {
		return false
	}
	if time.Now().After(sess.ExpiresAt) {
		s.Revoke(sessionID)
		return false
	}
	if sess.UserIP != clientIP {
		return false
	}
	return true
}

// Revoke removes a session (server-side logout).
func (s *AdminSessionStore) Revoke(sessionID string) {
	s.mu.Lock()
	delete(s.sessions, sessionID)
	s.mu.Unlock()
}

// Stop terminates the background cleanup goroutine.
func (s *AdminSessionStore) Stop() {
	close(s.stop)
}

func (s *AdminSessionStore) cleanupLoop() {
	ticker := time.NewTicker(adminSessionCleanupFreq)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			now := time.Now()
			s.mu.Lock()
			for id, sess := range s.sessions {
				if now.After(sess.ExpiresAt) {
					delete(s.sessions, id)
				}
			}
			s.mu.Unlock()
		case <-s.stop:
			return
		}
	}
}
