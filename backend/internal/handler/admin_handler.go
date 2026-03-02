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

// HandleAdminUserDetail returns user info with their devices and recent sessions.
// GET /v1/admin/users/{id}
func (h *AdminHandler) HandleAdminUserDetail(w http.ResponseWriter, r *http.Request) {
	if !h.adminAuth(r) {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	userID := r.PathValue("id")
	if userID == "" {
		writeError(w, "user id is required", http.StatusBadRequest)
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

	search := r.URL.Query().Get("search")
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
	if sessionID == "" {
		writeError(w, "session id is required", http.StatusBadRequest)
		return
	}

	sess, err := db.GetSession(h.DB, sessionID)
	if err != nil {
		slog.Error("admin get session failed", "error", err)
		writeError(w, "session not found", http.StatusNotFound)
		return
	}

	// Get user email for the session.
	var userEmail string
	_ = h.DB.QueryRow("SELECT email FROM users WHERE id = ?", sess.UserID).Scan(&userEmail)

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
			ID:          sess.ID,
			UserID:      sess.UserID,
			UserEmail:   userEmail,
			DeviceID:    sess.DeviceID,
			ProjectPath: sess.ProjectPath,
			GitBranch:   sess.GitBranch,
			CWD:         sess.CWD,
			Status:      string(sess.Status),
			StartedAt:   sess.StartedAt.Format(time.RFC3339),
			UpdatedAt:   sess.UpdatedAt.Format(time.RFC3339),
			TokensIn:    sess.TokensIn,
			TokensOut:   sess.TokensOut,
			TurnCount:   sess.TurnCount,
			Description: sess.Description,
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
	if userID == "" {
		writeError(w, "user id is required", http.StatusBadRequest)
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
	if userID == "" {
		writeError(w, "user id is required", http.StatusBadRequest)
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

	details, _ := json.Marshal(map[string]string{
		"userId": userID,
		"email":  user.Email,
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
	if deviceID == "" {
		writeError(w, "device id is required", http.StatusBadRequest)
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
	if deviceID == "" {
		writeError(w, "device id is required", http.StatusBadRequest)
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
	if sessionID == "" {
		writeError(w, "session id is required", http.StatusBadRequest)
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
