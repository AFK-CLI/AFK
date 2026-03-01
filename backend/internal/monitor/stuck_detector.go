package monitor

import (
	"database/sql"
	"log/slog"
	"sync"
	"time"

	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/ws"
)

// StuckDetector monitors sessions that have been "running" for too long
// without an update and sends push notifications for them.
type StuckDetector struct {
	database  *sql.DB
	hub       *ws.Hub
	threshold time.Duration // how long before a session is "stuck"
	interval  time.Duration // how often to check
	stop      chan struct{}

	// Notification tracking: prevents spamming the same session repeatedly.
	mu       sync.Mutex
	notified map[string]*stuckState // sessionID -> state
}

type stuckState struct {
	firstSeen  time.Time
	notifyCount int
}

const (
	maxNotifications    = 3              // stop pushing after this many notifications per session
	autoResolveAfter    = 30 * time.Minute // auto-mark idle after being stuck this long
)

func NewStuckDetector(database *sql.DB, hub *ws.Hub, threshold, interval time.Duration) *StuckDetector {
	return &StuckDetector{
		database:  database,
		hub:       hub,
		threshold: threshold,
		interval:  interval,
		stop:      make(chan struct{}),
		notified:  make(map[string]*stuckState),
	}
}

func (d *StuckDetector) Start() {
	go func() {
		ticker := time.NewTicker(d.interval)
		defer ticker.Stop()
		slog.Info("stuck detector started", "threshold", d.threshold, "interval", d.interval)

		for {
			select {
			case <-ticker.C:
				d.check()
			case <-d.stop:
				slog.Info("stuck detector stopped")
				return
			}
		}
	}()
}

func (d *StuckDetector) Stop() {
	close(d.stop)
}

func (d *StuckDetector) check() {
	sessions, err := db.ListStuckSessions(d.database, d.threshold)
	if err != nil {
		slog.Error("failed to list stuck sessions", "error", err)
		return
	}

	if len(sessions) == 0 {
		// Clean up stale tracking entries.
		d.mu.Lock()
		if len(d.notified) > 0 {
			d.notified = make(map[string]*stuckState)
		}
		d.mu.Unlock()
		return
	}

	// Build set of current stuck IDs for cleanup.
	currentStuck := make(map[string]bool, len(sessions))

	for _, s := range sessions {
		currentStuck[s.ID] = true
		stuckDuration := time.Since(s.UpdatedAt).Round(time.Second)

		// Check if agent is still connected — if not, the session is stale.
		agent := d.hub.GetAgentConn(s.DeviceID)
		if agent == nil {
			slog.Info("agent not connected for stuck session, marking idle", "device_id", s.DeviceID, "session_id", s.ID)
			_ = db.UpdateSessionStatus(d.database, s.ID, "idle")
			d.clearState(s.ID)
			continue
		}

		// Agent is connected. Get or create tracking state.
		d.mu.Lock()
		state, exists := d.notified[s.ID]
		if !exists {
			state = &stuckState{firstSeen: time.Now()}
			d.notified[s.ID] = state
			d.mu.Unlock()

			// First time seeing this stuck session — log and notify.
			slog.Warn("stuck session detected", "session_id", s.ID, "project", s.ProjectPath, "stuck_duration", stuckDuration, "user_id", s.UserID)
		} else {
			d.mu.Unlock()
		}

		// Auto-resolve: if stuck for too long, the heartbeat reconciliation
		// should have already caught it. Force-mark idle as a safety net.
		if time.Since(state.firstSeen) > autoResolveAfter {
			slog.Info("auto-resolving stuck session", "session_id", s.ID, "stuck_duration", stuckDuration, "auto_resolve_after", autoResolveAfter)
			_ = db.UpdateSessionStatus(d.database, s.ID, "idle")
			d.clearState(s.ID)
			continue
		}

		// Send push notification (max N times per session).
		if state.notifyCount < maxNotifications && d.hub.Notifier != nil {
			state.notifyCount++
			go d.hub.Notifier.NotifySessionError(
				s.UserID,
				s.ID,
				"Session may be stuck — no activity for "+stuckDuration.String(),
			)
		}
	}

	// Clean up tracking for sessions that are no longer stuck.
	d.mu.Lock()
	for id := range d.notified {
		if !currentStuck[id] {
			delete(d.notified, id)
		}
	}
	d.mu.Unlock()
}

func (d *StuckDetector) clearState(sessionID string) {
	d.mu.Lock()
	delete(d.notified, sessionID)
	d.mu.Unlock()
}
