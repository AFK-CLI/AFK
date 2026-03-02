package handler

import (
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/metrics"
	"github.com/AFK/afk-cloud/internal/model"
	"github.com/AFK/afk-cloud/internal/ws"
)

const adminCookieName = "afk_admin_session"
const adminCookieMaxAge = 24 * time.Hour

// redactEmail returns a privacy-safe representation: first char + "***@" + domain.
func redactEmail(email string) string {
	parts := strings.SplitN(email, "@", 2)
	if len(parts) != 2 || len(parts[0]) == 0 {
		return "***"
	}
	return string(parts[0][0]) + "***@" + parts[1]
}

type AdminHandler struct {
	DB          *sql.DB
	AdminSecret string
	Hub         *ws.Hub
	Collector   *metrics.Collector
	Version     string
}

// adminAuth checks admin authentication via X-Admin-Secret header or session cookie.
// Returns true if authenticated.
func (h *AdminHandler) adminAuth(r *http.Request) bool {
	if h.AdminSecret == "" {
		return false
	}

	// Method 1: X-Admin-Secret header (for curl/API).
	secret := r.Header.Get("X-Admin-Secret")
	if secret != "" && subtle.ConstantTimeCompare([]byte(secret), []byte(h.AdminSecret)) == 1 {
		return true
	}

	// Method 2: session cookie (for browser).
	cookie, err := r.Cookie(adminCookieName)
	if err != nil || cookie.Value == "" {
		return false
	}

	// Cookie format: base64(timestamp.HMAC-SHA256(adminSecret, timestamp))
	decoded, err := base64.RawURLEncoding.DecodeString(cookie.Value)
	if err != nil {
		return false
	}

	parts := strings.SplitN(string(decoded), ".", 2)
	if len(parts) != 2 {
		return false
	}

	timestamp := parts[0]
	signature := parts[1]

	// Verify HMAC.
	mac := hmac.New(sha256.New, []byte(h.AdminSecret))
	mac.Write([]byte(timestamp))
	expected := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	if subtle.ConstantTimeCompare([]byte(signature), []byte(expected)) != 1 {
		return false
	}

	// Check expiry.
	ts, err := strconv.ParseInt(timestamp, 10, 64)
	if err != nil {
		return false
	}
	if time.Since(time.Unix(ts, 0)) > adminCookieMaxAge {
		return false
	}

	return true
}

// makeAdminCookie creates an HMAC-signed session cookie value.
func (h *AdminHandler) makeAdminCookie() string {
	timestamp := fmt.Sprintf("%d", time.Now().Unix())
	mac := hmac.New(sha256.New, []byte(h.AdminSecret))
	mac.Write([]byte(timestamp))
	signature := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	raw := timestamp + "." + signature
	return base64.RawURLEncoding.EncodeToString([]byte(raw))
}

// HandleAdminLogin validates the admin secret and sets a session cookie.
// POST /v1/admin/login
func (h *AdminHandler) HandleAdminLogin(w http.ResponseWriter, r *http.Request) {
	if h.AdminSecret == "" {
		writeError(w, "admin API not configured", http.StatusServiceUnavailable)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 64*1024)
	var req struct {
		Secret string `json:"secret"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if subtle.ConstantTimeCompare([]byte(req.Secret), []byte(h.AdminSecret)) != 1 {
		writeError(w, "invalid secret", http.StatusUnauthorized)
		return
	}

	http.SetCookie(w, &http.Cookie{
		Name:     adminCookieName,
		Value:    h.makeAdminCookie(),
		Path:     "/",
		MaxAge:   int(adminCookieMaxAge.Seconds()),
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
		Secure:   r.TLS != nil,
	})

	slog.Info("admin login successful", "ip", r.RemoteAddr)
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// HandleAdminDashboard returns aggregated dashboard stats as JSON.
// GET /v1/admin/dashboard
func (h *AdminHandler) HandleAdminDashboard(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	stats, err := db.AdminDashboardStats(h.DB)
	if err != nil {
		slog.Error("admin dashboard stats failed", "error", err)
		writeError(w, "failed to fetch stats", http.StatusInternalServerError)
		return
	}

	// Add runtime metrics from collector.
	agentConns, iosConns := h.Hub.ConnectionCounts()

	response := map[string]interface{}{
		"stats": stats,
		"runtime": map[string]interface{}{
			"version":           h.version(),
			"uptime":            int64(h.Collector.Uptime().Seconds()),
			"agentConnections":  agentConns,
			"iosConnections":    iosConns,
			"requestsTotal":     h.Collector.RequestsTotal.Load(),
			"requestErrors":     h.Collector.RequestErrors.Load(),
			"wsMessagesReceived": h.Collector.WSMessagesReceived.Load(),
			"wsMessagesSent":    h.Collector.WSMessagesSent.Load(),
			"wsDroppedMessages": h.Collector.WSDroppedMessages.Load(),
			"rateLimitHits":     h.Collector.RateLimitHits.Load(),
		},
	}

	// DB size.
	var pageCount, pageSize int64
	h.DB.QueryRow("PRAGMA page_count").Scan(&pageCount)
	h.DB.QueryRow("PRAGMA page_size").Scan(&pageSize)
	response["dbSizeBytes"] = pageCount * pageSize

	writeJSON(w, http.StatusOK, response)
}

// HandleAdminUsers returns a paginated user list.
// GET /v1/admin/users?search=&limit=50&offset=0
func (h *AdminHandler) HandleAdminUsers(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	search := r.URL.Query().Get("search")
	limit := parseIntParam(r, "limit", 50)
	offset := parseIntParam(r, "offset", 0)

	users, total, err := db.AdminListUsers(h.DB, search, limit, offset)
	if err != nil {
		slog.Error("admin list users failed", "error", err)
		writeError(w, "failed to list users", http.StatusInternalServerError)
		return
	}

	if users == nil {
		users = []db.AdminUser{}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"users": users,
		"total": total,
	})
}

// HandleAdminTimeseries returns timeseries data for a given metric.
// GET /v1/admin/timeseries?metric=registrations|sessions|commands|tokens&days=30
func (h *AdminHandler) HandleAdminTimeseries(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	metric := r.URL.Query().Get("metric")
	days := parseIntParam(r, "days", 30)
	if days > 365 {
		days = 365
	}

	switch metric {
	case "registrations":
		points, err := db.AdminRegistrationTimeseries(h.DB, days)
		if err != nil {
			writeError(w, "failed to fetch timeseries", http.StatusInternalServerError)
			return
		}
		if points == nil {
			points = []db.TimeseriesPoint{}
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{"points": points})

	case "sessions":
		points, err := db.AdminSessionTimeseries(h.DB, days)
		if err != nil {
			writeError(w, "failed to fetch timeseries", http.StatusInternalServerError)
			return
		}
		if points == nil {
			points = []db.TimeseriesPoint{}
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{"points": points})

	case "commands":
		points, err := db.AdminCommandTimeseries(h.DB, days)
		if err != nil {
			writeError(w, "failed to fetch timeseries", http.StatusInternalServerError)
			return
		}
		if points == nil {
			points = []db.TimeseriesPoint{}
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{"points": points})

	case "tokens":
		points, err := db.AdminTokenTimeseries(h.DB, days)
		if err != nil {
			writeError(w, "failed to fetch timeseries", http.StatusInternalServerError)
			return
		}
		if points == nil {
			points = []db.TokenTimeseriesPoint{}
		}
		writeJSON(w, http.StatusOK, map[string]interface{}{"points": points})

	default:
		writeError(w, "invalid metric: use registrations, sessions, commands, or tokens", http.StatusBadRequest)
	}
}

// HandleAdminAudit returns audit log entries with optional filters.
// GET /v1/admin/audit?limit=50&offset=0&action=&user_id=
func (h *AdminHandler) HandleAdminAudit(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	action := r.URL.Query().Get("action")
	userID := r.URL.Query().Get("user_id")
	limit := parseIntParam(r, "limit", 50)
	offset := parseIntParam(r, "offset", 0)

	entries, total, err := db.AdminListAuditLogAll(h.DB, action, userID, limit, offset)
	if err != nil {
		slog.Error("admin list audit log failed", "error", err)
		writeError(w, "failed to list audit log", http.StatusInternalServerError)
		return
	}

	if entries == nil {
		entries = []db.AdminAuditEntry{}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"entries": entries,
		"total":   total,
	})
}

// HandleAdminLoginAttempts returns login attempts with optional success filter.
// GET /v1/admin/login-attempts?limit=50&offset=0&success=
func (h *AdminHandler) HandleAdminLoginAttempts(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	successFilter := r.URL.Query().Get("success")
	limit := parseIntParam(r, "limit", 50)
	offset := parseIntParam(r, "offset", 0)

	attempts, total, err := db.AdminListLoginAttempts(h.DB, successFilter, limit, offset)
	if err != nil {
		slog.Error("admin list login attempts failed", "error", err)
		writeError(w, "failed to list login attempts", http.StatusInternalServerError)
		return
	}

	failedHour, failed24h, _ := db.AdminFailedLoginStats(h.DB)

	if attempts == nil {
		attempts = []db.AdminLoginAttempt{}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"attempts":           attempts,
		"total":              total,
		"failedLastHour":     failedHour,
		"failedLast24Hours":  failed24h,
	})
}

// HandleAdminTopProjects returns projects ranked by session count.
// GET /v1/admin/top-projects?limit=10
func (h *AdminHandler) HandleAdminTopProjects(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	limit := parseIntParam(r, "limit", 10)

	projects, err := db.AdminTopProjects(h.DB, limit)
	if err != nil {
		slog.Error("admin top projects failed", "error", err)
		writeError(w, "failed to list projects", http.StatusInternalServerError)
		return
	}

	if projects == nil {
		projects = []db.AdminProject{}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"projects": projects})
}

// HandleAdminStaleDevices returns devices not seen in the given number of days.
// GET /v1/admin/stale-devices?days=30
func (h *AdminHandler) HandleAdminStaleDevices(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	days := parseIntParam(r, "days", 30)

	devices, err := db.AdminStaleDevices(h.DB, days)
	if err != nil {
		slog.Error("admin stale devices failed", "error", err)
		writeError(w, "failed to list stale devices", http.StatusInternalServerError)
		return
	}

	if devices == nil {
		devices = []db.AdminStaleDevice{}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{"devices": devices})
}

// HandleGrantContributor grants lifetime contributor tier to a user.
// POST /v1/admin/grant-contributor
// Authenticated via X-Admin-Secret header (CLI/curl use, not from iOS app).
func (h *AdminHandler) HandleGrantContributor(w http.ResponseWriter, r *http.Request) {
	if h.AdminSecret == "" {
		writeError(w, "admin API not configured", http.StatusServiceUnavailable)
		return
	}

	secret := r.Header.Get("X-Admin-Secret")
	if subtle.ConstantTimeCompare([]byte(secret), []byte(h.AdminSecret)) != 1 {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 64*1024) // 64 KB
	var req struct {
		Email  string `json:"email"`
		UserID string `json:"userId"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if req.Email == "" && req.UserID == "" {
		writeError(w, "email or userId is required", http.StatusBadRequest)
		return
	}

	// Look up user by email or ID.
	var user *model.User
	var err error
	if req.UserID != "" {
		user, err = db.GetUser(h.DB, req.UserID)
	} else {
		user, err = db.GetUserByEmail(h.DB, req.Email)
	}
	if err != nil {
		writeError(w, "user not found", http.StatusNotFound)
		return
	}

	// Set contributor tier with no expiry (lifetime).
	if err := db.UpdateUserSubscription(h.DB, user.ID, "contributor", "", "", nil); err != nil {
		slog.Error("failed to grant contributor tier", "user_id", user.ID, "error", err)
		writeError(w, "failed to update subscription", http.StatusInternalServerError)
		return
	}

	slog.Info("contributor tier granted", "user_id", user.ID, "email", redactEmail(user.Email))

	// Audit log.
	details, _ := json.Marshal(map[string]string{
		"user_id": user.ID,
		"email":   user.Email,
		"tier":    "contributor",
	})
	_ = db.InsertAuditLog(h.DB, &model.AuditLogEntry{
		UserID:  user.ID,
		Action:  "contributor_granted",
		Details: string(details),
	})

	// Return updated user info.
	user.SubscriptionTier = "contributor"
	user.SubscriptionExpiresAt = nil
	writeJSON(w, http.StatusOK, user)
}

func (h *AdminHandler) version() string {
	if h.Version != "" {
		return h.Version
	}
	return "dev"
}

// parseIntParam reads an integer query parameter with a default value.
func parseIntParam(r *http.Request, name string, defaultVal int) int {
	v := r.URL.Query().Get(name)
	if v == "" {
		return defaultVal
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 {
		return defaultVal
	}
	return n
}
