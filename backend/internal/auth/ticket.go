package auth

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"log/slog"
	"sync"
	"time"
)

const (
	ticketTTL             = 30 * time.Second
	ticketCleanupInterval = 60 * time.Second
	ticketIDBytes         = 32
)

// Ticket represents a single-use, short-lived WebSocket authentication ticket.
type Ticket struct {
	ID        string
	UserID    string
	DeviceID  string
	CreatedAt time.Time
	Used      bool
}

// TicketStore manages in-memory WebSocket tickets.
//
// TODO: If multi-instance deployment needed, move to SQLite table with
// DELETE WHERE used=1 OR created_at < now()-30s
type TicketStore struct {
	mu      sync.Mutex
	tickets map[string]*Ticket
}

// NewTicketStore creates an empty TicketStore.
func NewTicketStore() *TicketStore {
	return &TicketStore{
		tickets: make(map[string]*Ticket),
	}
}

// Issue generates a cryptographically random ticket, stores it, and returns the hex-encoded ID.
func (s *TicketStore) Issue(userID, deviceID string) string {
	b := make([]byte, ticketIDBytes)
	if _, err := rand.Read(b); err != nil {
		// crypto/rand.Read should never fail on a properly configured system.
		panic("crypto/rand.Read failed: " + err.Error())
	}
	id := hex.EncodeToString(b)

	s.mu.Lock()
	defer s.mu.Unlock()

	s.tickets[id] = &Ticket{
		ID:        id,
		UserID:    userID,
		DeviceID:  deviceID,
		CreatedAt: time.Now(),
		Used:      false,
	}

	return id
}

// Redeem validates and consumes a ticket. It returns an error if the ticket does
// not exist, has already been used, or has expired (30s TTL).
func (s *TicketStore) Redeem(ticketID string) (*Ticket, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	t, ok := s.tickets[ticketID]
	if !ok {
		return nil, errors.New("ticket not found")
	}

	if t.Used {
		return nil, errors.New("ticket already used")
	}

	if time.Since(t.CreatedAt) > ticketTTL {
		delete(s.tickets, ticketID)
		return nil, errors.New("ticket expired")
	}

	t.Used = true
	return t, nil
}

// StartCleanup launches a background goroutine that prunes expired and used
// tickets every 60 seconds. It stops when the provided stop channel is closed.
func (s *TicketStore) StartCleanup(stop <-chan struct{}) {
	go func() {
		ticker := time.NewTicker(ticketCleanupInterval)
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

func (s *TicketStore) cleanup() {
	s.mu.Lock()
	defer s.mu.Unlock()

	now := time.Now()
	pruned := 0
	for id, t := range s.tickets {
		if t.Used || now.Sub(t.CreatedAt) > ticketTTL {
			delete(s.tickets, id)
			pruned++
		}
	}
	if pruned > 0 {
		slog.Info("pruned expired/used tickets", "count", pruned)
	}
}
