package auth

import (
	"errors"
	"sync"
	"time"
)

type NonceStore struct {
	mu   sync.Mutex
	seen map[string]time.Time
	ttl  time.Duration
}

func NewNonceStore(ttl time.Duration) *NonceStore {
	return &NonceStore{
		seen: make(map[string]time.Time),
		ttl:  ttl,
	}
}

// Check returns an error if the nonce has been seen before.
// If the nonce is new, it records it and returns nil.
func (s *NonceStore) Check(nonce string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.seen[nonce]; exists {
		return errors.New("nonce already used")
	}
	s.seen[nonce] = time.Now()
	return nil
}

// Cleanup removes expired nonces. Call periodically.
func (s *NonceStore) Cleanup() {
	s.mu.Lock()
	defer s.mu.Unlock()
	cutoff := time.Now().Add(-s.ttl)
	for k, v := range s.seen {
		if v.Before(cutoff) {
			delete(s.seen, k)
		}
	}
}
