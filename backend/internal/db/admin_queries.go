package db

import (
	"database/sql"
	"fmt"
	"time"
)

// Admin dashboard aggregate types.

type AdminStats struct {
	// Users
	TotalUsers         int            `json:"totalUsers"`
	RegisteredToday    int            `json:"registeredToday"`
	RegisteredThisWeek int            `json:"registeredThisWeek"`
	DAU                int            `json:"dau"`
	WAU                int            `json:"wau"`
	MAU                int            `json:"mau"`
	UsersByTier        map[string]int `json:"usersByTier"`
	UsersByAuth        map[string]int `json:"usersByAuth"`

	// Devices
	TotalDevices    int            `json:"totalDevices"`
	OnlineDevices   int            `json:"onlineDevices"`
	OfflineDevices  int            `json:"offlineDevices"`
	E2EEDevices     int            `json:"e2eeDevices"`
	StaleDevices    int            `json:"staleDevices"`
	ByPrivacyMode   map[string]int `json:"byPrivacyMode"`

	// Sessions
	TotalSessions    int            `json:"totalSessions"`
	SessionsByStatus map[string]int `json:"sessionsByStatus"`
	AvgDuration      float64        `json:"avgDuration"`
	AvgTurnCount     float64        `json:"avgTurnCount"`
	TotalTokensIn    int64          `json:"totalTokensIn"`
	TotalTokensOut   int64          `json:"totalTokensOut"`

	// Commands
	CommandsByStatus map[string]int `json:"commandsByStatus"`

	// Push
	TotalPushTokens    int            `json:"totalPushTokens"`
	PushByPlatform     map[string]int `json:"pushByPlatform"`
}

type TimeseriesPoint struct {
	Date  string `json:"date"`
	Count int    `json:"count"`
}

type TokenTimeseriesPoint struct {
	Date     string `json:"date"`
	TokensIn int64  `json:"tokensIn"`
	TokensOut int64 `json:"tokensOut"`
}

type AdminUser struct {
	ID               string  `json:"id"`
	Email            string  `json:"email"`
	DisplayName      string  `json:"displayName"`
	SubscriptionTier string  `json:"subscriptionTier"`
	AuthMethod       string  `json:"authMethod"`
	DeviceCount      int     `json:"deviceCount"`
	SessionCount     int     `json:"sessionCount"`
	CreatedAt        string  `json:"createdAt"`
}

type AdminLoginAttempt struct {
	Email       string `json:"email"`
	AttemptedAt string `json:"attemptedAt"`
	Success     bool   `json:"success"`
	IPAddress   string `json:"ipAddress"`
}

type AdminProject struct {
	ID           string `json:"id"`
	UserID       string `json:"userId"`
	Name         string `json:"name"`
	Path         string `json:"path"`
	SessionCount int    `json:"sessionCount"`
}

type AdminStaleDevice struct {
	ID         string `json:"id"`
	UserID     string `json:"userId"`
	Name       string `json:"name"`
	LastSeenAt string `json:"lastSeenAt"`
	IsRevoked  bool   `json:"isRevoked"`
}

// AdminDashboardStats returns all aggregate metrics for the admin dashboard in a single call.
func AdminDashboardStats(db *sql.DB) (*AdminStats, error) {
	s := &AdminStats{
		UsersByTier:      make(map[string]int),
		UsersByAuth:      make(map[string]int),
		ByPrivacyMode:    make(map[string]int),
		SessionsByStatus: make(map[string]int),
		CommandsByStatus: make(map[string]int),
		PushByPlatform:   make(map[string]int),
	}

	// Total users.
	db.QueryRow("SELECT COUNT(*) FROM users").Scan(&s.TotalUsers)

	// Registered today.
	db.QueryRow("SELECT COUNT(*) FROM users WHERE date(created_at) = date('now')").Scan(&s.RegisteredToday)

	// Registered this week.
	db.QueryRow("SELECT COUNT(*) FROM users WHERE created_at >= datetime('now', '-7 days')").Scan(&s.RegisteredThisWeek)

	// DAU: users with session activity today.
	db.QueryRow(`SELECT COUNT(DISTINCT user_id) FROM sessions WHERE date(updated_at) = date('now')`).Scan(&s.DAU)

	// WAU: users with session activity this week.
	db.QueryRow(`SELECT COUNT(DISTINCT user_id) FROM sessions WHERE updated_at >= datetime('now', '-7 days')`).Scan(&s.WAU)

	// MAU: users with session activity this month.
	db.QueryRow(`SELECT COUNT(DISTINCT user_id) FROM sessions WHERE updated_at >= datetime('now', '-30 days')`).Scan(&s.MAU)

	// Users by tier.
	rows, err := db.Query("SELECT subscription_tier, COUNT(*) FROM users GROUP BY subscription_tier")
	if err == nil {
		defer rows.Close()
		for rows.Next() {
			var tier string
			var count int
			if rows.Scan(&tier, &count) == nil {
				s.UsersByTier[tier] = count
			}
		}
	}

	// Users by auth method.
	var appleCount, emailCount, noneCount int
	db.QueryRow("SELECT COUNT(*) FROM users WHERE apple_user_id IS NOT NULL AND apple_user_id != ''").Scan(&appleCount)
	db.QueryRow("SELECT COUNT(*) FROM users WHERE password_hash IS NOT NULL AND password_hash != ''").Scan(&emailCount)
	db.QueryRow(`SELECT COUNT(*) FROM users WHERE (apple_user_id IS NULL OR apple_user_id = '') AND (password_hash IS NULL OR password_hash = '')`).Scan(&noneCount)
	s.UsersByAuth["apple"] = appleCount
	s.UsersByAuth["email"] = emailCount
	s.UsersByAuth["none"] = noneCount

	// Total devices.
	db.QueryRow("SELECT COUNT(*) FROM devices WHERE is_revoked = 0").Scan(&s.TotalDevices)

	// Online/offline.
	db.QueryRow("SELECT COUNT(*) FROM devices WHERE is_online = 1 AND is_revoked = 0").Scan(&s.OnlineDevices)
	s.OfflineDevices = s.TotalDevices - s.OnlineDevices

	// E2EE enabled devices.
	db.QueryRow("SELECT COUNT(*) FROM devices WHERE key_agreement_public_key IS NOT NULL AND key_agreement_public_key != '' AND is_revoked = 0").Scan(&s.E2EEDevices)

	// Stale devices (not seen in 30 days).
	db.QueryRow("SELECT COUNT(*) FROM devices WHERE last_seen_at < datetime('now', '-30 days') AND is_revoked = 0").Scan(&s.StaleDevices)

	// Devices by privacy mode.
	rows2, err := db.Query("SELECT privacy_mode, COUNT(*) FROM devices WHERE is_revoked = 0 GROUP BY privacy_mode")
	if err == nil {
		defer rows2.Close()
		for rows2.Next() {
			var mode string
			var count int
			if rows2.Scan(&mode, &count) == nil {
				s.ByPrivacyMode[mode] = count
			}
		}
	}

	// Total sessions.
	db.QueryRow("SELECT COUNT(*) FROM sessions").Scan(&s.TotalSessions)

	// Sessions by status.
	rows3, err := db.Query("SELECT status, COUNT(*) FROM sessions GROUP BY status")
	if err == nil {
		defer rows3.Close()
		for rows3.Next() {
			var status string
			var count int
			if rows3.Scan(&status, &count) == nil {
				s.SessionsByStatus[status] = count
			}
		}
	}

	// Avg duration (seconds) for completed sessions.
	db.QueryRow(`SELECT COALESCE(AVG(julianday(updated_at) - julianday(started_at)) * 86400, 0)
		FROM sessions WHERE status IN ('completed', 'idle')`).Scan(&s.AvgDuration)

	// Avg turn count.
	db.QueryRow("SELECT COALESCE(AVG(turn_count), 0) FROM sessions WHERE turn_count > 0").Scan(&s.AvgTurnCount)

	// Total tokens.
	db.QueryRow("SELECT COALESCE(SUM(tokens_in), 0), COALESCE(SUM(tokens_out), 0) FROM sessions").Scan(&s.TotalTokensIn, &s.TotalTokensOut)

	// Commands by status.
	rows4, err := db.Query("SELECT status, COUNT(*) FROM commands GROUP BY status")
	if err == nil {
		defer rows4.Close()
		for rows4.Next() {
			var status string
			var count int
			if rows4.Scan(&status, &count) == nil {
				s.CommandsByStatus[status] = count
			}
		}
	}

	// Push tokens.
	db.QueryRow("SELECT COUNT(*) FROM push_tokens").Scan(&s.TotalPushTokens)

	// Push by platform.
	rows5, err := db.Query("SELECT platform, COUNT(*) FROM push_tokens GROUP BY platform")
	if err == nil {
		defer rows5.Close()
		for rows5.Next() {
			var platform string
			var count int
			if rows5.Scan(&platform, &count) == nil {
				s.PushByPlatform[platform] = count
			}
		}
	}

	return s, nil
}

// AdminRegistrationTimeseries returns daily registration counts for the last N days.
func AdminRegistrationTimeseries(db *sql.DB, days int) ([]TimeseriesPoint, error) {
	rows, err := db.Query(`
		SELECT date(created_at) as d, COUNT(*) as c
		FROM users
		WHERE created_at >= datetime('now', ? || ' days')
		GROUP BY d ORDER BY d
	`, fmt.Sprintf("-%d", days))
	if err != nil {
		return nil, fmt.Errorf("registration timeseries: %w", err)
	}
	defer rows.Close()

	return scanTimeseries(rows)
}

// AdminSessionTimeseries returns daily new session counts for the last N days.
func AdminSessionTimeseries(db *sql.DB, days int) ([]TimeseriesPoint, error) {
	rows, err := db.Query(`
		SELECT date(started_at) as d, COUNT(*) as c
		FROM sessions
		WHERE started_at >= datetime('now', ? || ' days')
		GROUP BY d ORDER BY d
	`, fmt.Sprintf("-%d", days))
	if err != nil {
		return nil, fmt.Errorf("session timeseries: %w", err)
	}
	defer rows.Close()

	return scanTimeseries(rows)
}

// AdminCommandTimeseries returns daily command counts for the last N days.
func AdminCommandTimeseries(db *sql.DB, days int) ([]TimeseriesPoint, error) {
	rows, err := db.Query(`
		SELECT date(created_at) as d, COUNT(*) as c
		FROM commands
		WHERE created_at >= datetime('now', ? || ' days')
		GROUP BY d ORDER BY d
	`, fmt.Sprintf("-%d", days))
	if err != nil {
		return nil, fmt.Errorf("command timeseries: %w", err)
	}
	defer rows.Close()

	return scanTimeseries(rows)
}

// AdminTokenTimeseries returns daily token usage for the last N days.
func AdminTokenTimeseries(db *sql.DB, days int) ([]TokenTimeseriesPoint, error) {
	rows, err := db.Query(`
		SELECT date(started_at) as d, COALESCE(SUM(tokens_in), 0), COALESCE(SUM(tokens_out), 0)
		FROM sessions
		WHERE started_at >= datetime('now', ? || ' days')
		GROUP BY d ORDER BY d
	`, fmt.Sprintf("-%d", days))
	if err != nil {
		return nil, fmt.Errorf("token timeseries: %w", err)
	}
	defer rows.Close()

	var points []TokenTimeseriesPoint
	for rows.Next() {
		var p TokenTimeseriesPoint
		if err := rows.Scan(&p.Date, &p.TokensIn, &p.TokensOut); err != nil {
			return nil, fmt.Errorf("scan token timeseries: %w", err)
		}
		points = append(points, p)
	}
	return points, nil
}

// AdminListUsers returns a paginated user list with device/session counts.
func AdminListUsers(d *sql.DB, search string, limit, offset int) ([]AdminUser, int, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}

	// Count total matching users.
	var total int
	var countQuery string
	var countArgs []interface{}
	if search != "" {
		countQuery = "SELECT COUNT(*) FROM users WHERE email LIKE ? OR display_name LIKE ?"
		pattern := "%" + search + "%"
		countArgs = []interface{}{pattern, pattern}
	} else {
		countQuery = "SELECT COUNT(*) FROM users"
	}
	if err := d.QueryRow(countQuery, countArgs...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("count users: %w", err)
	}

	// Query users with aggregated counts.
	query := `
		SELECT u.id, u.email, u.display_name, u.subscription_tier,
			CASE
				WHEN u.apple_user_id IS NOT NULL AND u.apple_user_id != '' THEN 'apple'
				WHEN u.password_hash IS NOT NULL AND u.password_hash != '' THEN 'email'
				ELSE 'unknown'
			END as auth_method,
			(SELECT COUNT(*) FROM devices WHERE user_id = u.id AND is_revoked = 0) as device_count,
			(SELECT COUNT(*) FROM sessions WHERE user_id = u.id) as session_count,
			u.created_at
		FROM users u
	`
	var args []interface{}
	if search != "" {
		query += " WHERE u.email LIKE ? OR u.display_name LIKE ?"
		pattern := "%" + search + "%"
		args = append(args, pattern, pattern)
	}
	query += " ORDER BY u.created_at DESC LIMIT ? OFFSET ?"
	args = append(args, limit, offset)

	rows, err := d.Query(query, args...)
	if err != nil {
		return nil, 0, fmt.Errorf("list users: %w", err)
	}
	defer rows.Close()

	var users []AdminUser
	for rows.Next() {
		var u AdminUser
		var createdAt time.Time
		if err := rows.Scan(&u.ID, &u.Email, &u.DisplayName, &u.SubscriptionTier,
			&u.AuthMethod, &u.DeviceCount, &u.SessionCount, &createdAt); err != nil {
			return nil, 0, fmt.Errorf("scan user: %w", err)
		}
		u.CreatedAt = createdAt.Format(time.RFC3339)
		users = append(users, u)
	}
	return users, total, nil
}

// AdminListAuditLogAll returns all audit log entries (across all users) with optional filters.
func AdminListAuditLogAll(d *sql.DB, action, userID string, limit, offset int) ([]AdminAuditEntry, int, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}

	// Build WHERE clause.
	var conditions []string
	var args []interface{}
	if action != "" {
		conditions = append(conditions, "a.action = ?")
		args = append(args, action)
	}
	if userID != "" {
		conditions = append(conditions, "a.user_id = ?")
		args = append(args, userID)
	}

	where := ""
	if len(conditions) > 0 {
		where = " WHERE " + joinStrings(conditions, " AND ")
	}

	// Count.
	var total int
	countQ := "SELECT COUNT(*) FROM audit_log a" + where
	if err := d.QueryRow(countQ, args...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("count audit log: %w", err)
	}

	// Query.
	query := `SELECT a.id, a.user_id, COALESCE(a.device_id, ''), a.action, a.details,
		COALESCE(a.ip_address, ''), a.created_at, COALESCE(u.email, '')
		FROM audit_log a LEFT JOIN users u ON a.user_id = u.id` + where +
		" ORDER BY a.created_at DESC LIMIT ? OFFSET ?"
	queryArgs := append(args, limit, offset)

	rows, err := d.Query(query, queryArgs...)
	if err != nil {
		return nil, 0, fmt.Errorf("list audit log: %w", err)
	}
	defer rows.Close()

	var entries []AdminAuditEntry
	for rows.Next() {
		var e AdminAuditEntry
		if err := rows.Scan(&e.ID, &e.UserID, &e.DeviceID, &e.Action, &e.Details,
			&e.IPAddress, &e.CreatedAt, &e.UserEmail); err != nil {
			return nil, 0, fmt.Errorf("scan audit log: %w", err)
		}
		entries = append(entries, e)
	}
	return entries, total, nil
}

type AdminAuditEntry struct {
	ID        string `json:"id"`
	UserID    string `json:"userId"`
	DeviceID  string `json:"deviceId"`
	Action    string `json:"action"`
	Details   string `json:"details"`
	IPAddress string `json:"ipAddress"`
	CreatedAt string `json:"createdAt"`
	UserEmail string `json:"userEmail"`
}

// AdminListLoginAttempts returns login attempts with optional success filter.
func AdminListLoginAttempts(d *sql.DB, successFilter string, limit, offset int) ([]AdminLoginAttempt, int, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}

	var where string
	var args []interface{}
	if successFilter == "true" {
		where = " WHERE success = 1"
	} else if successFilter == "false" {
		where = " WHERE success = 0"
	}

	var total int
	if err := d.QueryRow("SELECT COUNT(*) FROM login_attempts"+where, args...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("count login attempts: %w", err)
	}

	query := "SELECT email, attempted_at, success, COALESCE(ip_address, '') FROM login_attempts" +
		where + " ORDER BY attempted_at DESC LIMIT ? OFFSET ?"
	queryArgs := append(args, limit, offset)

	rows, err := d.Query(query, queryArgs...)
	if err != nil {
		return nil, 0, fmt.Errorf("list login attempts: %w", err)
	}
	defer rows.Close()

	var attempts []AdminLoginAttempt
	for rows.Next() {
		var a AdminLoginAttempt
		var success int
		if err := rows.Scan(&a.Email, &a.AttemptedAt, &success, &a.IPAddress); err != nil {
			return nil, 0, fmt.Errorf("scan login attempt: %w", err)
		}
		a.Success = success == 1
		attempts = append(attempts, a)
	}
	return attempts, total, nil
}

// AdminFailedLoginStats returns failed login counts for the last hour and last 24 hours.
func AdminFailedLoginStats(d *sql.DB) (lastHour, last24h int, err error) {
	d.QueryRow("SELECT COUNT(*) FROM login_attempts WHERE success = 0 AND attempted_at >= datetime('now', '-1 hour')").Scan(&lastHour)
	d.QueryRow("SELECT COUNT(*) FROM login_attempts WHERE success = 0 AND attempted_at >= datetime('now', '-24 hours')").Scan(&last24h)
	return lastHour, last24h, nil
}

// AdminTopProjects returns projects ranked by session count.
func AdminTopProjects(d *sql.DB, limit int) ([]AdminProject, error) {
	if limit <= 0 {
		limit = 10
	}

	rows, err := d.Query(`
		SELECT p.id, p.user_id, p.name, p.path, COUNT(s.id) as session_count
		FROM projects p
		LEFT JOIN sessions s ON s.project_id = p.id
		GROUP BY p.id
		ORDER BY session_count DESC
		LIMIT ?
	`, limit)
	if err != nil {
		return nil, fmt.Errorf("top projects: %w", err)
	}
	defer rows.Close()

	var projects []AdminProject
	for rows.Next() {
		var p AdminProject
		if err := rows.Scan(&p.ID, &p.UserID, &p.Name, &p.Path, &p.SessionCount); err != nil {
			return nil, fmt.Errorf("scan project: %w", err)
		}
		projects = append(projects, p)
	}
	return projects, nil
}

// AdminStaleDevices returns devices not seen in the given number of days.
func AdminStaleDevices(d *sql.DB, days int) ([]AdminStaleDevice, error) {
	if days <= 0 {
		days = 30
	}

	rows, err := d.Query(`
		SELECT id, user_id, name, last_seen_at, is_revoked
		FROM devices
		WHERE last_seen_at < datetime('now', ? || ' days') AND is_revoked = 0
		ORDER BY last_seen_at ASC
		LIMIT 100
	`, fmt.Sprintf("-%d", days))
	if err != nil {
		return nil, fmt.Errorf("stale devices: %w", err)
	}
	defer rows.Close()

	var devices []AdminStaleDevice
	for rows.Next() {
		var d AdminStaleDevice
		var isRevoked int
		var lastSeen time.Time
		if err := rows.Scan(&d.ID, &d.UserID, &d.Name, &lastSeen, &isRevoked); err != nil {
			return nil, fmt.Errorf("scan stale device: %w", err)
		}
		d.LastSeenAt = lastSeen.Format(time.RFC3339)
		d.IsRevoked = isRevoked == 1
		devices = append(devices, d)
	}
	return devices, nil
}

// Helper to scan timeseries rows.
func scanTimeseries(rows *sql.Rows) ([]TimeseriesPoint, error) {
	var points []TimeseriesPoint
	for rows.Next() {
		var p TimeseriesPoint
		if err := rows.Scan(&p.Date, &p.Count); err != nil {
			return nil, fmt.Errorf("scan timeseries: %w", err)
		}
		points = append(points, p)
	}
	return points, nil
}

// joinStrings joins string slice with separator (avoids importing strings for a one-liner).
func joinStrings(parts []string, sep string) string {
	if len(parts) == 0 {
		return ""
	}
	result := parts[0]
	for _, p := range parts[1:] {
		result += sep + p
	}
	return result
}
