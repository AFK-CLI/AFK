package handler

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"os"
	"time"

	"github.com/AFK/afk-cloud/internal/metrics"
	"github.com/AFK/afk-cloud/internal/ws"
)

type HealthHandler struct {
	Hub       *ws.Hub
	DB        *sql.DB
	Collector *metrics.Collector
	Version   string
}

// HandleLiveness returns a minimal public health check (no sensitive details).
// Suitable for load balancers and uptime monitors.
func (h *HealthHandler) HandleLiveness(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// Handle returns detailed health information including connection counts,
// stats, and DB size. Should be placed behind auth middleware.
// NOTE: main.go must route /healthz to HandleLiveness (public) and
// /healthz/detail to Handle (behind auth middleware).
func (h *HealthHandler) Handle(w http.ResponseWriter, r *http.Request) {
	agentCount, iosCount := h.Hub.ConnectionCounts()

	response := map[string]interface{}{
		"status":  "ok",
		"time":    time.Now().UTC().Format(time.RFC3339),
		"version": h.version(),
		"uptime":  int64(h.Collector.Uptime().Seconds()),
		"connections": map[string]int{
			"agents": agentCount,
			"ios":    iosCount,
		},
		"stats": map[string]int64{
			"requests":    h.Collector.RequestsTotal.Load(),
			"errors":      h.Collector.RequestErrors.Load(),
			"ws_received": h.Collector.WSMessagesReceived.Load(),
			"ws_sent":     h.Collector.WSMessagesSent.Load(),
			"ws_dropped":  h.Collector.WSDroppedMessages.Load(),
			"commands":    h.Collector.CommandsSubmitted.Load(),
		},
	}

	// DB size
	if h.DB != nil {
		var pageCount, pageSize int64
		h.DB.QueryRow("PRAGMA page_count").Scan(&pageCount)
		h.DB.QueryRow("PRAGMA page_size").Scan(&pageSize)
		response["db_size_bytes"] = pageCount * pageSize
	}

	writeJSON(w, http.StatusOK, response)
}

func (h *HealthHandler) version() string {
	if h.Version != "" {
		return h.Version
	}
	if v := os.Getenv("AFK_VERSION"); v != "" {
		return v
	}
	return "dev"
}

// Shared helpers

func writeJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(data)
}

func writeError(w http.ResponseWriter, message string, status int) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"error": message})
}
