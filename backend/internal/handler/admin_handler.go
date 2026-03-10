package handler

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/metrics"
	"github.com/AFK/afk-cloud/internal/middleware"
	"github.com/AFK/afk-cloud/internal/model"
	"github.com/AFK/afk-cloud/internal/ws"
	"github.com/pquerna/otp/totp"
	"golang.org/x/crypto/bcrypt"
)

const adminCookieName = "afk_admin_session"

// redactEmail returns a privacy-safe representation: first char + "***@" + domain.
func redactEmail(email string) string {
	parts := strings.SplitN(email, "@", 2)
	if len(parts) != 2 || len(parts[0]) == 0 {
		return "***"
	}
	return string(parts[0][0]) + "***@" + parts[1]
}

// truncatedAdminIP masks an IP address for privacy in admin logs: IPv4 /24, IPv6 /48.
func truncatedAdminIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return "invalid"
	}
	if v4 := ip.To4(); v4 != nil {
		v4[3] = 0
		return v4.String()
	}
	full := ip.To16()
	for i := 6; i < 16; i++ {
		full[i] = 0
	}
	return full.String()
}

// adminClientIP extracts the raw client IP (no port) from the request.
func adminClientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// csvEscape wraps a value in double quotes and escapes any inner double quotes.
func csvEscape(s string) string {
	return `"` + strings.ReplaceAll(s, `"`, `""`) + `"`
}

// sanitizeSearchQuery caps search input length to prevent abuse.
func sanitizeSearchQuery(q string) string {
	if len(q) > 256 {
		return q[:256]
	}
	return q
}

// validatePathParam validates a path parameter length.
func validatePathParam(w http.ResponseWriter, value, name string) bool {
	if value == "" {
		writeError(w, name+" is required", http.StatusBadRequest)
		return false
	}
	if len(value) > 128 {
		writeError(w, name+" too long", http.StatusBadRequest)
		return false
	}
	return true
}

type AdminHandler struct {
	DB                    *sql.DB
	Hub                   *ws.Hub
	Collector             *metrics.Collector
	Version               string
	SessionStore          *AdminSessionStore
	WebAuthn              *webauthn.WebAuthn
	WebAuthnSessionStore  *auth.WebAuthnSessionStore
}

// adminAuth checks admin authentication via server-side session cookie.
// Returns true if authenticated.
func (h *AdminHandler) adminAuth(r *http.Request) bool {
	if h.SessionStore == nil {
		return false
	}
	cookie, err := r.Cookie(adminCookieName)
	if err != nil || cookie.Value == "" {
		return false
	}

	_, ok := h.SessionStore.ValidateAndGetAdminID(cookie.Value, adminClientIP(r))
	return ok
}

// isSecureRequest returns true if the request arrived over TLS or via HTTPS proxy.
// Only trusts X-Forwarded-Proto from configured trusted proxies.
func isSecureRequest(r *http.Request) bool {
	if r.TLS != nil {
		return true
	}
	if r.Header.Get("X-Forwarded-Proto") == "https" {
		return isTrustedProxy(r)
	}
	return false
}

// isTrustedProxy checks if the direct connection IP is in the trusted proxy set.
func isTrustedProxy(r *http.Request) bool {
	directIP, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		directIP = r.RemoteAddr
	}
	return middleware.IsTrustedProxy(directIP)
}

// adminDummyHash is a pre-computed bcrypt hash for timing-safe comparison
// when an admin login targets a non-existent user.
var adminDummyHash []byte

func init() {
	adminDummyHash, _ = bcrypt.GenerateFromPassword([]byte("admin-dummy-timing"), 12)
}

// HandleAdminLogin authenticates an admin user with email/password and optional TOTP.
// POST /v1/admin/login
func (h *AdminHandler) HandleAdminLogin(w http.ResponseWriter, r *http.Request) {
	if h.SessionStore == nil {
		writeError(w, "admin API not configured", http.StatusServiceUnavailable)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 64*1024)
	var req struct {
		Email    string `json:"email"`
		Password string `json:"password"`
		TOTPCode string `json:"totpCode"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if req.Email == "" || req.Password == "" {
		writeError(w, "email and password are required", http.StatusBadRequest)
		return
	}

	adminUser, err := db.GetAdminUserByEmail(h.DB, req.Email)
	if err != nil {
		// Timing-safe: run dummy bcrypt comparison for non-existent users.
		bcrypt.CompareHashAndPassword(adminDummyHash, []byte(req.Password))
		slog.Warn("admin login failed: user not found", "ip", truncatedAdminIP(r))
		writeError(w, "invalid email or password", http.StatusUnauthorized)
		return
	}

	if err := bcrypt.CompareHashAndPassword([]byte(adminUser.PasswordHash), []byte(req.Password)); err != nil {
		slog.Warn("admin login failed: wrong password", "ip", truncatedAdminIP(r))
		writeError(w, "invalid email or password", http.StatusUnauthorized)
		return
	}

	// Check TOTP if enabled.
	if adminUser.TOTPEnabled {
		if req.TOTPCode == "" {
			writeJSON(w, http.StatusOK, map[string]interface{}{
				"status":       "totp_required",
				"totpRequired": true,
			})
			return
		}
		if !totp.Validate(req.TOTPCode, adminUser.TOTPSecret) {
			slog.Warn("admin login failed: invalid TOTP", "ip", truncatedAdminIP(r))
			writeError(w, "invalid TOTP code", http.StatusUnauthorized)
			return
		}
	}

	sessionID, err := h.SessionStore.Create(adminUser.ID, adminClientIP(r))
	if err != nil {
		slog.Error("failed to create admin session", "error", err)
		writeError(w, "internal error", http.StatusInternalServerError)
		return
	}

	http.SetCookie(w, &http.Cookie{
		Name:     adminCookieName,
		Value:    sessionID,
		Path:     "/",
		MaxAge:   int(adminSessionMaxLifetime.Seconds()),
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
		Secure:   isSecureRequest(r),
	})

	slog.Info("admin login successful", "admin_id", adminUser.ID, "ip", truncatedAdminIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// HandleAdminLogout revokes the admin session and clears the cookie.
// POST /v1/admin/logout
func (h *AdminHandler) HandleAdminLogout(w http.ResponseWriter, r *http.Request) {
	cookie, err := r.Cookie(adminCookieName)
	if err == nil && cookie.Value != "" && h.SessionStore != nil {
		h.SessionStore.Revoke(cookie.Value)
	}

	http.SetCookie(w, &http.Cookie{
		Name:     adminCookieName,
		Value:    "",
		Path:     "/",
		MaxAge:   -1,
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
		Secure:   isSecureRequest(r),
	})

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
			"version":            h.version(),
			"uptime":             int64(h.Collector.Uptime().Seconds()),
			"agentConnections":   agentConns,
			"iosConnections":     iosConns,
			"requestsTotal":      h.Collector.RequestsTotal.Load(),
			"requestErrors":      h.Collector.RequestErrors.Load(),
			"wsMessagesReceived": h.Collector.WSMessagesReceived.Load(),
			"wsMessagesSent":     h.Collector.WSMessagesSent.Load(),
			"wsDroppedMessages":  h.Collector.WSDroppedMessages.Load(),
			"rateLimitHits":      h.Collector.RateLimitHits.Load(),
		},
	}

	// DB size.
	var dbSize int64
	h.DB.QueryRow("SELECT pg_database_size(current_database())").Scan(&dbSize)
	response["dbSizeBytes"] = dbSize

	writeJSON(w, http.StatusOK, response)
}

// HandleAdminUsers returns a paginated user list.
// GET /v1/admin/users?search=&limit=50&offset=0
func (h *AdminHandler) HandleAdminUsers(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	search := sanitizeSearchQuery(r.URL.Query().Get("search"))
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

	action := sanitizeSearchQuery(r.URL.Query().Get("action"))
	userID := sanitizeSearchQuery(r.URL.Query().Get("user_id"))
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

	// Truncate IPs for privacy but keep emails visible for admin.
	for i := range attempts {
		attempts[i].IPAddress = truncateIPString(attempts[i].IPAddress)
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"attempts":          attempts,
		"total":             total,
		"failedLastHour":    failedHour,
		"failedLast24Hours": failed24h,
	})
}

// truncateIPString masks a raw IP string for privacy: IPv4 /24, IPv6 /48.
func truncateIPString(addr string) string {
	if addr == "" {
		return ""
	}
	ip := net.ParseIP(addr)
	if ip == nil {
		return "***"
	}
	if v4 := ip.To4(); v4 != nil {
		v4[3] = 0
		return v4.String()
	}
	full := ip.To16()
	for i := 6; i < 16; i++ {
		full[i] = 0
	}
	return full.String()
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
func (h *AdminHandler) HandleGrantContributor(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
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

	// Audit log (redact email in stored details).
	details, _ := json.Marshal(map[string]string{
		"user_id": user.ID,
		"email":   redactEmail(user.Email),
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

// HandleAdminUserDetail returns user info with their devices and recent sessions.
// GET /v1/admin/users/{id}
func (h *AdminHandler) HandleAdminUserDetail(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	userID := r.PathValue("id")
	if !validatePathParam(w, userID, "user id") {
		return
	}

	user, devices, sessions, err := db.AdminGetUserDetail(h.DB, userID)
	if err != nil {
		slog.Error("admin get user detail failed", "error", err)
		writeError(w, "user not found", http.StatusNotFound)
		return
	}

	if devices == nil {
		devices = []db.AdminDeviceDetail{}
	}
	if sessions == nil {
		sessions = []db.AdminSessionDetail{}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"user":           user,
		"devices":        devices,
		"recentSessions": sessions,
	})
}

// HandleAdminDevicesList returns a paginated device list.
// GET /v1/admin/devices?search=&limit=50&offset=0
func (h *AdminHandler) HandleAdminDevicesList(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	search := sanitizeSearchQuery(r.URL.Query().Get("search"))
	limit := parseIntParam(r, "limit", 50)
	offset := parseIntParam(r, "offset", 0)

	devices, total, err := db.AdminListDevices(h.DB, search, limit, offset)
	if err != nil {
		slog.Error("admin list devices failed", "error", err)
		writeError(w, "failed to list devices", http.StatusInternalServerError)
		return
	}

	if devices == nil {
		devices = []db.AdminDeviceDetail{}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"devices": devices,
		"total":   total,
	})
}

// HandleAdminSessionsList returns a paginated session list.
// GET /v1/admin/sessions?status=&limit=50&offset=0
func (h *AdminHandler) HandleAdminSessionsList(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	status := r.URL.Query().Get("status")
	limit := parseIntParam(r, "limit", 50)
	offset := parseIntParam(r, "offset", 0)

	sessions, total, err := db.AdminListSessions(h.DB, status, limit, offset)
	if err != nil {
		slog.Error("admin list sessions failed", "error", err)
		writeError(w, "failed to list sessions", http.StatusInternalServerError)
		return
	}

	if sessions == nil {
		sessions = []db.AdminSessionDetail{}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"sessions": sessions,
		"total":    total,
	})
}

// HandleAdminSessionDetail returns a single session with its commands.
// GET /v1/admin/sessions/{id}
func (h *AdminHandler) HandleAdminSessionDetail(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	sessionID := r.PathValue("id")
	if !validatePathParam(w, sessionID, "session id") {
		return
	}

	sess, err := db.GetSession(h.DB, sessionID)
	if err != nil {
		slog.Error("admin get session failed", "error", err)
		writeError(w, "session not found", http.StatusNotFound)
		return
	}

	// Get user email for the session.
	userEmail, _ := db.GetUserEmailByID(h.DB, sess.UserID)

	commands, err := db.AdminListSessionCommands(h.DB, sessionID)
	if err != nil {
		slog.Error("admin list session commands failed", "error", err)
		writeError(w, "failed to list commands", http.StatusInternalServerError)
		return
	}

	if commands == nil {
		commands = []db.AdminCommandDetail{}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"session": db.AdminSessionDetail{
			ID:        sess.ID,
			UserID:    sess.UserID,
			UserEmail: userEmail,
			DeviceID:  sess.DeviceID,
			Status:    string(sess.Status),
			StartedAt: sess.StartedAt.Format(time.RFC3339),
			UpdatedAt: sess.UpdatedAt.Format(time.RFC3339),
			TokensIn:  sess.TokensIn,
			TokensOut: sess.TokensOut,
			TurnCount: sess.TurnCount,
		},
		"commands": commands,
	})
}

// HandleAdminCommandsList returns a paginated command list.
// GET /v1/admin/commands?status=&limit=50&offset=0
func (h *AdminHandler) HandleAdminCommandsList(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	status := r.URL.Query().Get("status")
	limit := parseIntParam(r, "limit", 50)
	offset := parseIntParam(r, "offset", 0)

	commands, total, err := db.AdminListCommands(h.DB, status, limit, offset)
	if err != nil {
		slog.Error("admin list commands failed", "error", err)
		writeError(w, "failed to list commands", http.StatusInternalServerError)
		return
	}

	if commands == nil {
		commands = []db.AdminCommandDetail{}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"commands": commands,
		"total":    total,
	})
}

// HandleAdminUpdateUserTier updates a user's subscription tier.
// PUT /v1/admin/users/{id}/tier
func (h *AdminHandler) HandleAdminUpdateUserTier(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 64*1024)

	userID := r.PathValue("id")
	if !validatePathParam(w, userID, "user id") {
		return
	}

	var req struct {
		Tier string `json:"tier"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	validTiers := map[string]bool{"free": true, "pro": true, "contributor": true, "revoked": true}
	if !validTiers[req.Tier] {
		writeError(w, "invalid tier: must be free, pro, contributor, or revoked", http.StatusBadRequest)
		return
	}

	if err := db.UpdateUserSubscription(h.DB, userID, req.Tier, "", "", nil); err != nil {
		slog.Error("admin update user tier failed", "error", err)
		writeError(w, "failed to update tier", http.StatusInternalServerError)
		return
	}

	details, _ := json.Marshal(map[string]string{
		"userId":    userID,
		"tier":      req.Tier,
		"changedBy": "admin",
	})
	_ = db.InsertAuditLog(h.DB, &model.AuditLogEntry{
		UserID:  userID,
		Action:  "tier_changed",
		Details: string(details),
	})

	slog.Info("admin updated user tier", "user_id", userID, "tier", req.Tier)
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// HandleAdminRevokeUser revokes a user and all their devices.
// DELETE /v1/admin/users/{id}
func (h *AdminHandler) HandleAdminRevokeUser(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	userID := r.PathValue("id")
	if !validatePathParam(w, userID, "user id") {
		return
	}

	user, err := db.GetUser(h.DB, userID)
	if err != nil {
		writeError(w, "user not found", http.StatusNotFound)
		return
	}

	if err := db.AdminRevokeUser(h.DB, userID); err != nil {
		slog.Error("admin revoke user failed", "error", err)
		writeError(w, "failed to revoke user", http.StatusInternalServerError)
		return
	}

	// Redact email in stored audit log details.
	details, _ := json.Marshal(map[string]string{
		"userId": userID,
		"email":  redactEmail(user.Email),
	})
	_ = db.InsertAuditLog(h.DB, &model.AuditLogEntry{
		UserID:  userID,
		Action:  "user_revoked",
		Details: string(details),
	})

	slog.Info("admin revoked user", "user_id", userID, "email", redactEmail(user.Email))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// HandleAdminRevokeDevice revokes a single device.
// DELETE /v1/admin/devices/{id}
func (h *AdminHandler) HandleAdminRevokeDevice(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 64*1024)

	deviceID := r.PathValue("id")
	if !validatePathParam(w, deviceID, "device id") {
		return
	}

	var req struct {
		UserID string `json:"userId"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if req.UserID == "" {
		writeError(w, "userId is required", http.StatusBadRequest)
		return
	}

	if err := db.DeleteDevice(h.DB, deviceID, req.UserID); err != nil {
		slog.Error("admin revoke device failed", "error", err)
		writeError(w, "failed to revoke device", http.StatusInternalServerError)
		return
	}
	_ = db.RevokeDeviceKeys(h.DB, deviceID)

	details, _ := json.Marshal(map[string]string{
		"deviceId": deviceID,
		"userId":   req.UserID,
	})
	_ = db.InsertAuditLog(h.DB, &model.AuditLogEntry{
		UserID:   req.UserID,
		DeviceID: deviceID,
		Action:   "device_revoked",
		Details:  string(details),
	})

	slog.Info("admin revoked device", "device_id", deviceID, "user_id", req.UserID)
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// HandleAdminForceKeyRotation forces E2EE key rotation for a device.
// POST /v1/admin/devices/{id}/rotate-keys
func (h *AdminHandler) HandleAdminForceKeyRotation(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 64*1024)

	deviceID := r.PathValue("id")
	if !validatePathParam(w, deviceID, "device id") {
		return
	}

	var req struct {
		UserID string `json:"userId"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if req.UserID == "" {
		writeError(w, "userId is required", http.StatusBadRequest)
		return
	}

	if err := db.RevokeDeviceKeys(h.DB, deviceID); err != nil {
		slog.Error("admin force key rotation failed", "error", err)
		writeError(w, "failed to revoke device keys", http.StatusInternalServerError)
		return
	}

	// Broadcast key rotation to all user's clients.
	rotatedMsg, err := ws.NewWSMessage("device.key_rotated", model.DeviceKeyRotated{
		DeviceID: deviceID,
	})
	if err == nil {
		h.Hub.BroadcastToAll(req.UserID, rotatedMsg)
	}

	details, _ := json.Marshal(map[string]string{
		"deviceId": deviceID,
		"userId":   req.UserID,
	})
	_ = db.InsertAuditLog(h.DB, &model.AuditLogEntry{
		UserID:   req.UserID,
		DeviceID: deviceID,
		Action:   "keys_force_rotated",
		Details:  string(details),
	})

	slog.Info("admin forced key rotation", "device_id", deviceID, "user_id", req.UserID)
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// HandleAdminUpdateSessionStatus forces a session status change.
// PUT /v1/admin/sessions/{id}/status
func (h *AdminHandler) HandleAdminUpdateSessionStatus(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 64*1024)

	sessionID := r.PathValue("id")
	if !validatePathParam(w, sessionID, "session id") {
		return
	}

	var req struct {
		Status string `json:"status"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if req.Status != "completed" {
		writeError(w, "only 'completed' status is allowed", http.StatusBadRequest)
		return
	}

	if err := db.UpdateSessionStatus(h.DB, sessionID, model.StatusCompleted); err != nil {
		slog.Error("admin update session status failed", "error", err)
		writeError(w, "failed to update session status", http.StatusInternalServerError)
		return
	}

	details, _ := json.Marshal(map[string]string{
		"sessionId": sessionID,
	})
	_ = db.InsertAuditLog(h.DB, &model.AuditLogEntry{
		Action:  "session_force_ended",
		Details: string(details),
	})

	slog.Info("admin force ended session", "session_id", sessionID)
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// HandleAdminLogs returns a paginated list of app logs with optional filters.
// GET /v1/admin/logs?level=&source=&user_id=&email=&subsystem=&limit=50&offset=0
func (h *AdminHandler) HandleAdminLogs(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	level := sanitizeSearchQuery(r.URL.Query().Get("level"))
	source := sanitizeSearchQuery(r.URL.Query().Get("source"))
	userID := sanitizeSearchQuery(r.URL.Query().Get("user_id"))
	email := sanitizeSearchQuery(r.URL.Query().Get("email"))
	subsystem := sanitizeSearchQuery(r.URL.Query().Get("subsystem"))
	limit := parseIntParam(r, "limit", 50)
	offset := parseIntParam(r, "offset", 0)

	logs, total, err := db.AdminListAppLogs(h.DB, level, source, userID, email, subsystem, limit, offset)
	if err != nil {
		slog.Error("admin list app logs failed", "error", err)
		writeError(w, "failed to list logs", http.StatusInternalServerError)
		return
	}

	if logs == nil {
		logs = []db.AdminAppLog{}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"logs":  logs,
		"total": total,
	})
}

// HandleAdminLogsExport returns all matching logs as CSV.
// GET /v1/admin/logs/export?level=&source=&email=&subsystem=
func (h *AdminHandler) HandleAdminLogsExport(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	level := sanitizeSearchQuery(r.URL.Query().Get("level"))
	source := sanitizeSearchQuery(r.URL.Query().Get("source"))
	userID := sanitizeSearchQuery(r.URL.Query().Get("user_id"))
	email := sanitizeSearchQuery(r.URL.Query().Get("email"))
	subsystem := sanitizeSearchQuery(r.URL.Query().Get("subsystem"))

	logs, _, err := db.AdminListAppLogs(h.DB, level, source, userID, email, subsystem, 10000, 0)
	if err != nil {
		slog.Error("admin export logs failed", "error", err)
		writeError(w, "failed to export logs", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "text/csv")
	w.Header().Set("Content-Disposition", "attachment; filename=logs_export.csv")

	// Write CSV header
	_, _ = w.Write([]byte("Time,Level,Source,Subsystem,User,Device,Message,Metadata\n"))
	for _, l := range logs {
		line := csvEscape(l.CreatedAt) + "," +
			csvEscape(l.Level) + "," +
			csvEscape(l.Source) + "," +
			csvEscape(l.Subsystem) + "," +
			csvEscape(l.UserEmail) + "," +
			csvEscape(l.DeviceID) + "," +
			csvEscape(l.Message) + "," +
			csvEscape(l.Metadata) + "\n"
		_, _ = w.Write([]byte(line))
	}
}

// HandleAdminFeedback returns a paginated list of feedback entries with optional filters.
// GET /v1/admin/feedback?category=&user_id=&limit=50&offset=0
func (h *AdminHandler) HandleAdminFeedback(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	category := sanitizeSearchQuery(r.URL.Query().Get("category"))
	userID := sanitizeSearchQuery(r.URL.Query().Get("user_id"))
	limit := parseIntParam(r, "limit", 50)
	offset := parseIntParam(r, "offset", 0)

	feedback, total, err := db.AdminListFeedback(h.DB, category, userID, limit, offset)
	if err != nil {
		slog.Error("admin list feedback failed", "error", err)
		writeError(w, "failed to list feedback", http.StatusInternalServerError)
		return
	}

	if feedback == nil {
		feedback = []db.AdminFeedbackEntry{}
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"feedback": feedback,
		"total":    total,
	})
}

// HandleAdminBetaRequests returns a paginated list of beta access requests.
// GET /v1/admin/beta-requests?status=&limit=50&offset=0
func (h *AdminHandler) HandleAdminBetaRequests(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	status := r.URL.Query().Get("status")
	limit := parseIntParam(r, "limit", 50)
	offset := parseIntParam(r, "offset", 0)

	requests, err := db.ListBetaRequests(h.DB, status, limit, offset)
	if err != nil {
		slog.Error("admin list beta requests failed", "error", err)
		writeError(w, "failed to list beta requests", http.StatusInternalServerError)
		return
	}

	total, err := db.CountBetaRequests(h.DB, status)
	if err != nil {
		slog.Error("admin count beta requests failed", "error", err)
		writeError(w, "failed to count beta requests", http.StatusInternalServerError)
		return
	}

	if requests == nil {
		requests = []model.BetaRequest{}
	}

	// Beta emails intentionally NOT redacted: admin needs raw emails to send invites.

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"requests": requests,
		"total":    total,
	})
}

// HandleAdminUpdateBetaRequest updates the status and notes of a beta request.
// PUT /v1/admin/beta-requests/{id}
func (h *AdminHandler) HandleAdminUpdateBetaRequest(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 64*1024)

	id := r.PathValue("id")
	if !validatePathParam(w, id, "beta request id") {
		return
	}

	var req struct {
		Status string `json:"status"`
		Notes  string `json:"notes"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	validStatuses := map[string]bool{"pending": true, "invited": true, "declined": true}
	if !validStatuses[req.Status] {
		writeError(w, "invalid status: must be pending, invited, or declined", http.StatusBadRequest)
		return
	}

	if len(req.Notes) > 1000 {
		req.Notes = req.Notes[:1000]
	}

	if err := db.UpdateBetaRequestStatus(h.DB, id, req.Status, req.Notes); err != nil {
		if strings.Contains(err.Error(), "not found") {
			writeError(w, "beta request not found", http.StatusNotFound)
			return
		}
		slog.Error("admin update beta request failed", "error", err)
		writeError(w, "failed to update beta request", http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// adminAuthGetID checks admin authentication and returns the admin user ID.
func (h *AdminHandler) adminAuthGetID(r *http.Request) (string, bool) {
	if h.SessionStore == nil {
		return "", false
	}
	cookie, err := r.Cookie(adminCookieName)
	if err != nil || cookie.Value == "" {
		return "", false
	}
	return h.SessionStore.ValidateAndGetAdminID(cookie.Value, adminClientIP(r))
}

// HandleAdminPasskeyRegisterBegin starts passkey registration for an authenticated admin.
// POST /v1/admin/passkey/register/begin
func (h *AdminHandler) HandleAdminPasskeyRegisterBegin(w http.ResponseWriter, r *http.Request) {
	adminID, ok := h.adminAuthGetID(r)
	if !ok {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	if h.WebAuthn == nil || h.WebAuthnSessionStore == nil {
		writeError(w, "passkey not configured", http.StatusServiceUnavailable)
		return
	}

	adminUser, err := db.GetAdminUserByID(h.DB, adminID)
	if err != nil {
		writeError(w, "admin user not found", http.StatusNotFound)
		return
	}

	existingCreds, err := h.buildAdminWebAuthnCredentials(adminID)
	if err != nil {
		slog.Error("failed to load admin passkey credentials", "error", err)
		writeError(w, "internal error", http.StatusInternalServerError)
		return
	}

	waUser := &auth.WebAuthnUser{
		ID:          adminUser.ID,
		Name:        adminUser.Email,
		DisplayName: adminUser.Email,
		Credentials: existingCreds,
	}

	options, session, err := h.WebAuthn.BeginRegistration(waUser,
		webauthn.WithResidentKeyRequirement(protocol.ResidentKeyRequirementRequired),
		webauthn.WithExclusions(webauthn.Credentials(existingCreds).CredentialDescriptors()),
	)
	if err != nil {
		slog.Error("failed to begin admin passkey registration", "error", err)
		writeError(w, "failed to begin registration", http.StatusInternalServerError)
		return
	}

	sessionKey := h.WebAuthnSessionStore.Save(session)

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"publicKey":  options.Response,
		"sessionKey": sessionKey,
	})
}

// HandleAdminPasskeyRegisterFinish completes passkey registration for an admin.
// POST /v1/admin/passkey/register/finish
func (h *AdminHandler) HandleAdminPasskeyRegisterFinish(w http.ResponseWriter, r *http.Request) {
	adminID, ok := h.adminAuthGetID(r)
	if !ok {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	if h.WebAuthn == nil || h.WebAuthnSessionStore == nil {
		writeError(w, "passkey not configured", http.StatusServiceUnavailable)
		return
	}

	bodyBytes, err := io.ReadAll(r.Body)
	if err != nil {
		writeError(w, "failed to read request body", http.StatusBadRequest)
		return
	}
	r.Body = io.NopCloser(bytes.NewReader(bodyBytes))

	var envelope struct {
		SessionKey string `json:"sessionKey"`
	}
	_ = json.Unmarshal(bodyBytes, &envelope)
	if envelope.SessionKey == "" {
		writeError(w, "missing sessionKey", http.StatusBadRequest)
		return
	}

	sessionData, ok := h.WebAuthnSessionStore.Get(envelope.SessionKey)
	if !ok {
		writeError(w, "session expired or invalid", http.StatusBadRequest)
		return
	}

	adminUser, err := db.GetAdminUserByID(h.DB, adminID)
	if err != nil {
		writeError(w, "admin user not found", http.StatusNotFound)
		return
	}

	existingCreds, err := h.buildAdminWebAuthnCredentials(adminID)
	if err != nil {
		writeError(w, "internal error", http.StatusInternalServerError)
		return
	}

	waUser := &auth.WebAuthnUser{
		ID:          adminUser.ID,
		Name:        adminUser.Email,
		DisplayName: adminUser.Email,
		Credentials: existingCreds,
	}

	credential, err := h.WebAuthn.FinishRegistration(waUser, *sessionData, r)
	if err != nil {
		slog.Warn("admin passkey registration failed", "error", err, "admin_id", adminID)
		writeError(w, "registration verification failed", http.StatusBadRequest)
		return
	}

	transportJSON, _ := json.Marshal(credential.Transport)
	credID := auth.GenerateID()
	if err := db.CreateAdminPasskeyCredential(
		h.DB,
		credID,
		adminID,
		credential.ID,
		credential.PublicKey,
		credential.AttestationType,
		string(transportJSON),
		credential.Authenticator.AAGUID,
		"Admin Passkey",
		credential.Flags.BackupEligible,
		credential.Flags.BackupState,
	); err != nil {
		slog.Error("failed to store admin passkey credential", "error", err)
		writeError(w, "failed to store credential", http.StatusInternalServerError)
		return
	}

	slog.Info("admin passkey registered", "admin_id", adminID)
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// HandleAdminPasskeyLoginBegin starts passkey authentication for admin login.
// POST /v1/admin/passkey/login/begin
func (h *AdminHandler) HandleAdminPasskeyLoginBegin(w http.ResponseWriter, r *http.Request) {
	if h.WebAuthn == nil || h.WebAuthnSessionStore == nil {
		writeError(w, "passkey not configured", http.StatusServiceUnavailable)
		return
	}

	options, session, err := h.WebAuthn.BeginDiscoverableLogin()
	if err != nil {
		slog.Error("failed to begin admin passkey login", "error", err)
		writeError(w, "failed to begin login", http.StatusInternalServerError)
		return
	}

	sessionKey := h.WebAuthnSessionStore.Save(session)

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"publicKey":  options.Response,
		"sessionKey": sessionKey,
	})
}

// HandleAdminPasskeyLoginFinish completes passkey authentication and creates an admin session.
// POST /v1/admin/passkey/login/finish
func (h *AdminHandler) HandleAdminPasskeyLoginFinish(w http.ResponseWriter, r *http.Request) {
	if h.WebAuthn == nil || h.WebAuthnSessionStore == nil {
		writeError(w, "passkey not configured", http.StatusServiceUnavailable)
		return
	}
	if h.SessionStore == nil {
		writeError(w, "admin API not configured", http.StatusServiceUnavailable)
		return
	}

	bodyBytes, err := io.ReadAll(r.Body)
	if err != nil {
		writeError(w, "failed to read request body", http.StatusBadRequest)
		return
	}
	r.Body = io.NopCloser(bytes.NewReader(bodyBytes))

	var envelope struct {
		SessionKey string `json:"sessionKey"`
	}
	_ = json.Unmarshal(bodyBytes, &envelope)
	if envelope.SessionKey == "" {
		writeError(w, "missing sessionKey", http.StatusBadRequest)
		return
	}

	sessionData, ok := h.WebAuthnSessionStore.Get(envelope.SessionKey)
	if !ok {
		writeError(w, "session expired or invalid", http.StatusBadRequest)
		return
	}

	userHandler := func(rawID, userHandle []byte) (webauthn.User, error) {
		if len(userHandle) > 0 {
			adminUser, err := db.GetAdminUserByID(h.DB, string(userHandle))
			if err != nil {
				return nil, fmt.Errorf("admin user not found for handle: %w", err)
			}
			creds, err := h.buildAdminWebAuthnCredentials(adminUser.ID)
			if err != nil {
				return nil, err
			}
			return &auth.WebAuthnUser{
				ID:          adminUser.ID,
				Name:        adminUser.Email,
				DisplayName: adminUser.Email,
				Credentials: creds,
			}, nil
		}

		adminUser, _, err := db.GetAdminUserByPasskeyCredentialID(h.DB, rawID)
		if err != nil {
			return nil, fmt.Errorf("admin credential not found: %w", err)
		}
		creds, err := h.buildAdminWebAuthnCredentials(adminUser.ID)
		if err != nil {
			return nil, err
		}
		return &auth.WebAuthnUser{
			ID:          adminUser.ID,
			Name:        adminUser.Email,
			DisplayName: adminUser.Email,
			Credentials: creds,
		}, nil
	}

	credential, err := h.WebAuthn.FinishDiscoverableLogin(userHandler, *sessionData, r)
	if err != nil {
		slog.Warn("admin passkey login failed", "error", err)
		writeError(w, "authentication failed", http.StatusUnauthorized)
		return
	}

	adminUser, passkeyID, err := db.GetAdminUserByPasskeyCredentialID(h.DB, credential.ID)
	if err != nil {
		writeError(w, "credential not found", http.StatusUnauthorized)
		return
	}

	_ = db.UpdateAdminPasskeySignCount(h.DB, passkeyID, int(credential.Authenticator.SignCount))

	sessionID, err := h.SessionStore.Create(adminUser.ID, adminClientIP(r))
	if err != nil {
		slog.Error("failed to create admin session", "error", err)
		writeError(w, "internal error", http.StatusInternalServerError)
		return
	}

	http.SetCookie(w, &http.Cookie{
		Name:     adminCookieName,
		Value:    sessionID,
		Path:     "/",
		MaxAge:   int(adminSessionMaxLifetime.Seconds()),
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
		Secure:   isSecureRequest(r),
	})

	slog.Info("admin passkey login successful", "admin_id", adminUser.ID, "ip", truncatedAdminIP(r))
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// buildAdminWebAuthnCredentials loads admin passkey credentials from DB and converts them.
func (h *AdminHandler) buildAdminWebAuthnCredentials(adminUserID string) ([]webauthn.Credential, error) {
	dbCreds, err := db.GetAdminPasskeyCredentials(h.DB, adminUserID)
	if err != nil {
		return nil, fmt.Errorf("load admin passkey credentials: %w", err)
	}

	creds := make([]webauthn.Credential, 0, len(dbCreds))
	for _, dc := range dbCreds {
		var transports []protocol.AuthenticatorTransport
		_ = json.Unmarshal([]byte(dc.Transport), &transports)

		creds = append(creds, webauthn.Credential{
			ID:              dc.CredentialID,
			PublicKey:       dc.PublicKey,
			AttestationType: dc.AttestationType,
			Transport:       transports,
			Flags: webauthn.CredentialFlags{
				UserPresent:    true,
				UserVerified:   true,
				BackupEligible: dc.BackupEligible,
				BackupState:    dc.BackupState,
			},
			Authenticator: webauthn.Authenticator{
				AAGUID:       dc.AAGUID,
				SignCount:    uint32(dc.SignCount),
				CloneWarning: dc.CloneWarning,
			},
		})
	}
	return creds, nil
}

// HandleAdminMe returns the current admin user's profile info.
// GET /v1/admin/me
func (h *AdminHandler) HandleAdminMe(w http.ResponseWriter, r *http.Request) {
	adminID, ok := h.adminAuthGetID(r)
	if !ok {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	adminUser, err := db.GetAdminUserByID(h.DB, adminID)
	if err != nil {
		writeError(w, "admin user not found", http.StatusNotFound)
		return
	}

	passkeys, err := db.GetAdminPasskeyCredentials(h.DB, adminID)
	if err != nil {
		slog.Error("failed to load admin passkey credentials", "error", err)
		passkeys = nil
	}

	type passkeyInfo struct {
		ID           string `json:"id"`
		FriendlyName string `json:"friendlyName"`
		CreatedAt    string `json:"createdAt"`
		LastUsedAt   string `json:"lastUsedAt"`
	}
	passkeyList := make([]passkeyInfo, 0, len(passkeys))
	for _, p := range passkeys {
		passkeyList = append(passkeyList, passkeyInfo{
			ID:           p.ID,
			FriendlyName: p.FriendlyName,
			CreatedAt:    p.CreatedAt.Format(time.RFC3339),
			LastUsedAt:   p.LastUsedAt.Format(time.RFC3339),
		})
	}

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"id":           adminUser.ID,
		"email":        adminUser.Email,
		"totpEnabled":  adminUser.TOTPEnabled,
		"passkeyCount": len(passkeys),
		"passkeys":     passkeyList,
		"createdAt":    adminUser.CreatedAt,
	})
}

// HandleAdminTOTPSetup generates a TOTP secret and returns the otpauth URI.
// POST /v1/admin/totp/setup
func (h *AdminHandler) HandleAdminTOTPSetup(w http.ResponseWriter, r *http.Request) {
	adminID, ok := h.adminAuthGetID(r)
	if !ok {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	adminUser, err := db.GetAdminUserByID(h.DB, adminID)
	if err != nil {
		writeError(w, "admin user not found", http.StatusNotFound)
		return
	}

	if adminUser.TOTPEnabled {
		writeError(w, "TOTP is already enabled", http.StatusConflict)
		return
	}

	key, err := totp.Generate(totp.GenerateOpts{
		Issuer:      "AFK Admin",
		AccountName: adminUser.Email,
	})
	if err != nil {
		slog.Error("failed to generate TOTP key", "error", err)
		writeError(w, "failed to generate TOTP secret", http.StatusInternalServerError)
		return
	}

	// Store the secret (not yet enabled until verified).
	if err := db.SetAdminTOTPSecret(h.DB, adminID, key.Secret()); err != nil {
		slog.Error("failed to store TOTP secret", "error", err)
		writeError(w, "internal error", http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{
		"otpauthURI": key.URL(),
		"secret":     key.Secret(),
	})
}

// HandleAdminTOTPVerify verifies a TOTP code and enables TOTP for the admin user.
// POST /v1/admin/totp/verify
func (h *AdminHandler) HandleAdminTOTPVerify(w http.ResponseWriter, r *http.Request) {
	adminID, ok := h.adminAuthGetID(r)
	if !ok {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 4*1024)
	var req struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if len(req.Code) != 6 {
		writeError(w, "code must be 6 digits", http.StatusBadRequest)
		return
	}

	adminUser, err := db.GetAdminUserByID(h.DB, adminID)
	if err != nil {
		writeError(w, "admin user not found", http.StatusNotFound)
		return
	}

	if adminUser.TOTPEnabled {
		writeError(w, "TOTP is already enabled", http.StatusConflict)
		return
	}

	if adminUser.TOTPSecret == "" {
		writeError(w, "call /v1/admin/totp/setup first", http.StatusBadRequest)
		return
	}

	if !totp.Validate(req.Code, adminUser.TOTPSecret) {
		writeError(w, "invalid TOTP code", http.StatusBadRequest)
		return
	}

	if err := db.EnableAdminTOTP(h.DB, adminID); err != nil {
		slog.Error("failed to enable admin TOTP", "error", err)
		writeError(w, "internal error", http.StatusInternalServerError)
		return
	}

	slog.Info("admin TOTP enabled", "admin_id", adminID)
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (h *AdminHandler) version() string {
	if h.Version != "" {
		return h.Version
	}
	return "dev"
}

// parseIntParam reads an integer query parameter with a default value.
// Upper bounds: offset max 100000, limit max 200, days max 365.
func parseIntParam(r *http.Request, name string, defaultVal int) int {
	v := r.URL.Query().Get(name)
	if v == "" {
		return defaultVal
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 0 {
		return defaultVal
	}

	// Apply upper bounds based on parameter name.
	switch name {
	case "offset":
		if n > 100000 {
			n = 100000
		}
	case "limit":
		if n > 200 {
			n = 200
		}
	case "days":
		if n > 365 {
			n = 365
		}
	}

	return n
}
