package handler

import (
	"net/http"

	"github.com/AFK/afk-cloud/internal/metrics"
)

// MetricsHandler serves Prometheus-format metrics.
// Uses admin session cookie authentication.
type MetricsHandler struct {
	Collector    *metrics.Collector
	SessionStore *AdminSessionStore
}

func (h *MetricsHandler) Handle(w http.ResponseWriter, r *http.Request) {
	if h.SessionStore == nil {
		writeError(w, "metrics endpoint not configured", http.StatusServiceUnavailable)
		return
	}

	cookie, err := r.Cookie(adminCookieName)
	if err != nil || cookie.Value == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	if _, ok := h.SessionStore.ValidateAndGetAdminID(cookie.Value, adminClientIP(r)); !ok {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	w.Write([]byte(h.Collector.Prometheus()))
}
