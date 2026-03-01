package handler

import (
	"crypto/subtle"
	"net/http"

	"github.com/AFK/afk-cloud/internal/metrics"
)

// MetricsHandler serves Prometheus-format metrics.
// NOTE: main.go should place this behind admin auth middleware, or
// use the built-in AdminSecret check below.
type MetricsHandler struct {
	Collector   *metrics.Collector
	AdminSecret string
}

func (h *MetricsHandler) Handle(w http.ResponseWriter, r *http.Request) {
	// Require admin secret to be configured.
	if h.AdminSecret == "" {
		writeError(w, "metrics endpoint not configured", http.StatusServiceUnavailable)
		return
	}

	secret := r.Header.Get("X-Admin-Secret")
	if subtle.ConstantTimeCompare([]byte(secret), []byte(h.AdminSecret)) != 1 {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	w.Write([]byte(h.Collector.Prometheus()))
}
