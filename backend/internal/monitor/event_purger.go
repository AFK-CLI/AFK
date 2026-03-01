package monitor

import (
	"database/sql"
	"log/slog"
	"time"

	"github.com/AFK/afk-cloud/internal/db"
)

// EventPurger periodically deletes session events that exceed their TTL.
// Free users: 7-day retention. Pro/contributor users: 90-day retention.
type EventPurger struct {
	database *sql.DB
	interval time.Duration
	freeTTL  time.Duration
	proTTL   time.Duration
	stop     chan struct{}
}

func NewEventPurger(database *sql.DB, interval, freeTTL, proTTL time.Duration) *EventPurger {
	return &EventPurger{
		database: database,
		interval: interval,
		freeTTL:  freeTTL,
		proTTL:   proTTL,
		stop:     make(chan struct{}),
	}
}

func (p *EventPurger) Start() {
	go func() {
		ticker := time.NewTicker(p.interval)
		defer ticker.Stop()
		slog.Info("event purger started", "interval", p.interval, "free_ttl", p.freeTTL, "pro_ttl", p.proTTL)

		for {
			select {
			case <-ticker.C:
				p.purge()
			case <-p.stop:
				slog.Info("event purger stopped")
				return
			}
		}
	}()
}

func (p *EventPurger) Stop() {
	close(p.stop)
}

func (p *EventPurger) purge() {
	freeCutoff := time.Now().Add(-p.freeTTL)
	proCutoff := time.Now().Add(-p.proTTL)

	deleted, err := db.PurgeExpiredEvents(p.database, freeCutoff, proCutoff)
	if err != nil {
		slog.Error("event purge failed", "error", err)
		return
	}
	if deleted > 0 {
		slog.Info("purged expired events", "deleted", deleted, "free_cutoff", freeCutoff, "pro_cutoff", proCutoff)
	}
}
