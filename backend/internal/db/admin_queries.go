// TODO: Split this file — extract user queries into admin_queries_users.go,
// device queries into admin_queries_devices.go, and analytics into admin_queries_analytics.go.

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
	ID               string `json:"id"`
	Email            string `json:"email"`
	DisplayName      string `json:"displayName"`
	SubscriptionTier string `json:"subscriptionTier"`
	AuthMethod       string `json:"authMethod"`
	EmailVerified    bool   `json:"emailVerified"`
	DeviceCount      int    `json:"deviceCount"`
	SessionCount     int    `json:"sessionCount"`
	CreatedAt        string `json:"createdAt"`
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
	Name         string `json:"-"`
	Path         string `json:"-"`
	SessionCount int    `json:"sessionCount"`
}

type AdminStaleDevice struct {
	ID         string `json:"id"`
	UserID     string `json:"userId"`
	Name       string `json:"name"`
	LastSeenAt string `json:"lastSeenAt"`
	IsRevoked  bool   `json:"isRevoked"`
}

type AdminAppLog struct {
	ID        string `json:"id"`
	UserID    string `json:"userId"`
	UserEmail string `json:"userEmail"`
	DeviceID  string `json:"deviceId"`
	Source    string `json:"source"`
	Level     string `json:"level"`
	Subsystem string `json:"subsystem"`
	Message   string `json:"message"`
	Metadata  string `json:"metadata"`
	CreatedAt string `json:"createdAt"`
}

type AdminFeedbackEntry struct {
	ID         string `json:"id"`
	UserID     string `json:"userId"`
	UserEmail  string `json:"userEmail"`
	DeviceID   string `json:"deviceId"`
	Category   string `json:"category"`
	Message    string `json:"message"`
	AppVersion string `json:"appVersion"`
	Platform   string `json:"platform"`
	CreatedAt  string `json:"createdAt"`
}

// placeholderCounter is a helper for generating sequential PostgreSQL placeholders ($1, $2, ...).
type placeholderCounter struct {
	n int
}

func (p *placeholderCounter) Next() string {
	p.n++
	return fmt.Sprintf("$%d", p.n)
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
	db.QueryRow("SELECT COUNT(*) FROM users WHERE created_at::date = CURRENT_DATE").Scan(&s.RegisteredToday)

	// Registered this week.
	db.QueryRow("SELECT COUNT(*) FROM users WHERE created_at >= NOW() - INTERVAL '7 days'").Scan(&s.RegisteredThisWeek)

	// DAU: users with session activity today.
	db.QueryRow(`SELECT COUNT(DISTINCT user_id) FROM sessions WHERE updated_at::date = CURRENT_DATE`).Scan(&s.DAU)

	// WAU: users with session activity this week.
	db.QueryRow(`SELECT COUNT(DISTINCT user_id) FROM sessions WHERE updated_at >= NOW() - INTERVAL '7 days'`).Scan(&s.WAU)

	// MAU: users with session activity this month.
	db.QueryRow(`SELECT COUNT(DISTINCT user_id) FROM sessions WHERE updated_at >= NOW() - INTERVAL '30 days'`).Scan(&s.MAU)

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
	db.QueryRow("SELECT COUNT(*) FROM devices WHERE is_revoked = false").Scan(&s.TotalDevices)

	// Online/offline.
	db.QueryRow("SELECT COUNT(*) FROM devices WHERE is_online = true AND is_revoked = false").Scan(&s.OnlineDevices)
	s.OfflineDevices = s.TotalDevices - s.OnlineDevices

	// E2EE enabled devices.
	db.QueryRow("SELECT COUNT(*) FROM devices WHERE key_agreement_public_key IS NOT NULL AND key_agreement_public_key != '' AND is_revoked = false").Scan(&s.E2EEDevices)

	// Stale devices (not seen in 30 days).
	db.QueryRow("SELECT COUNT(*) FROM devices WHERE last_seen_at < NOW() - INTERVAL '30 days' AND is_revoked = false").Scan(&s.StaleDevices)

	// Devices by privacy mode.
	rows2, err := db.Query("SELECT privacy_mode, COUNT(*) FROM devices WHERE is_revoked = false GROUP BY privacy_mode")
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
	db.QueryRow(`SELECT COALESCE(AVG(EXTRACT(EPOCH FROM (updated_at - started_at))), 0)
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
		SELECT created_at::date as d, COUNT(*) as c
		FROM users
		WHERE created_at >= NOW() + ($1 * INTERVAL '1 day')
		GROUP BY d ORDER BY d
	`, -days)
	if err != nil {
		return nil, fmt.Errorf("registration timeseries: %w", err)
	}
	defer rows.Close()

	return scanTimeseries(rows)
}

// AdminSessionTimeseries returns daily new session counts for the last N days.
func AdminSessionTimeseries(db *sql.DB, days int) ([]TimeseriesPoint, error) {
	rows, err := db.Query(`
		SELECT started_at::date as d, COUNT(*) as c
		FROM sessions
		WHERE started_at >= NOW() + ($1 * INTERVAL '1 day')
		GROUP BY d ORDER BY d
	`, -days)
	if err != nil {
		return nil, fmt.Errorf("session timeseries: %w", err)
	}
	defer rows.Close()

	return scanTimeseries(rows)
}

// AdminCommandTimeseries returns daily command counts for the last N days.
func AdminCommandTimeseries(db *sql.DB, days int) ([]TimeseriesPoint, error) {
	rows, err := db.Query(`
		SELECT created_at::date as d, COUNT(*) as c
		FROM commands
		WHERE created_at >= NOW() + ($1 * INTERVAL '1 day')
		GROUP BY d ORDER BY d
	`, -days)
	if err != nil {
		return nil, fmt.Errorf("command timeseries: %w", err)
	}
	defer rows.Close()

	return scanTimeseries(rows)
}

// AdminTokenTimeseries returns daily token usage for the last N days.
func AdminTokenTimeseries(db *sql.DB, days int) ([]TokenTimeseriesPoint, error) {
	rows, err := db.Query(`
		SELECT started_at::date as d, COALESCE(SUM(tokens_in), 0), COALESCE(SUM(tokens_out), 0)
		FROM sessions
		WHERE started_at >= NOW() + ($1 * INTERVAL '1 day')
		GROUP BY d ORDER BY d
	`, -days)
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
		countQuery = "SELECT COUNT(*) FROM users WHERE email ILIKE $1 OR display_name ILIKE $2"
		pattern := "%" + search + "%"
		countArgs = []interface{}{pattern, pattern}
	} else {
		countQuery = "SELECT COUNT(*) FROM users"
	}
	if err := d.QueryRow(countQuery, countArgs...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("count users: %w", err)
	}

	// Query users with aggregated counts.
	var args []interface{}
	var ph placeholderCounter
	query := `
		SELECT u.id, u.email, u.display_name, u.subscription_tier,
			CASE
				WHEN u.apple_user_id IS NOT NULL AND u.apple_user_id != '' THEN 'apple'
				WHEN u.password_hash IS NOT NULL AND u.password_hash != '' THEN 'email'
				ELSE 'unknown'
			END as auth_method,
			COALESCE(u.email_verified, true) as email_verified,
			(SELECT COUNT(*) FROM devices WHERE user_id = u.id AND is_revoked = false) as device_count,
			(SELECT COUNT(*) FROM sessions WHERE user_id = u.id) as session_count,
			u.created_at
		FROM users u
	`
	if search != "" {
		p1 := ph.Next()
		p2 := ph.Next()
		query += " WHERE u.email ILIKE " + p1 + " OR u.display_name ILIKE " + p2
		pattern := "%" + search + "%"
		args = append(args, pattern, pattern)
	}
	p3 := ph.Next()
	p4 := ph.Next()
	query += " ORDER BY u.created_at DESC LIMIT " + p3 + " OFFSET " + p4
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
			&u.AuthMethod, &u.EmailVerified, &u.DeviceCount, &u.SessionCount, &createdAt); err != nil {
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
	var ph placeholderCounter
	var conditions []string
	var args []interface{}
	if action != "" {
		conditions = append(conditions, "a.action = "+ph.Next())
		args = append(args, action)
	}
	if userID != "" {
		conditions = append(conditions, "a.user_id = "+ph.Next())
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

	// Query — we need a separate placeholder counter for the query since it reuses the same arg values
	// but PostgreSQL requires separate $N sequences per statement.
	var ph2 placeholderCounter
	var conditions2 []string
	var queryArgs []interface{}
	if action != "" {
		conditions2 = append(conditions2, "a.action = "+ph2.Next())
		queryArgs = append(queryArgs, action)
	}
	if userID != "" {
		conditions2 = append(conditions2, "a.user_id = "+ph2.Next())
		queryArgs = append(queryArgs, userID)
	}
	where2 := ""
	if len(conditions2) > 0 {
		where2 = " WHERE " + joinStrings(conditions2, " AND ")
	}

	query := `SELECT a.id, a.user_id, COALESCE(a.device_id, ''), a.action, a.details,
		COALESCE(a.ip_address, ''), a.created_at, COALESCE(u.email, '')
		FROM audit_log a LEFT JOIN users u ON a.user_id = u.id` + where2 +
		" ORDER BY a.created_at DESC LIMIT " + ph2.Next() + " OFFSET " + ph2.Next()
	queryArgs = append(queryArgs, limit, offset)

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
		where = " WHERE success = true"
	} else if successFilter == "false" {
		where = " WHERE success = false"
	}

	var total int
	if err := d.QueryRow("SELECT COUNT(*) FROM login_attempts"+where, args...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("count login attempts: %w", err)
	}

	query := "SELECT email, attempted_at, success, COALESCE(ip_address, '') FROM login_attempts" +
		where + " ORDER BY attempted_at DESC LIMIT $1 OFFSET $2"
	queryArgs := append(args, limit, offset)

	rows, err := d.Query(query, queryArgs...)
	if err != nil {
		return nil, 0, fmt.Errorf("list login attempts: %w", err)
	}
	defer rows.Close()

	var attempts []AdminLoginAttempt
	for rows.Next() {
		var a AdminLoginAttempt
		if err := rows.Scan(&a.Email, &a.AttemptedAt, &a.Success, &a.IPAddress); err != nil {
			return nil, 0, fmt.Errorf("scan login attempt: %w", err)
		}
		attempts = append(attempts, a)
	}
	return attempts, total, nil
}

// AdminFailedLoginStats returns failed login counts for the last hour and last 24 hours.
func AdminFailedLoginStats(d *sql.DB) (lastHour, last24h int, err error) {
	d.QueryRow("SELECT COUNT(*) FROM login_attempts WHERE success = false AND attempted_at >= NOW() - INTERVAL '1 hour'").Scan(&lastHour)
	d.QueryRow("SELECT COUNT(*) FROM login_attempts WHERE success = false AND attempted_at >= NOW() - INTERVAL '24 hours'").Scan(&last24h)
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
		LIMIT $1
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
		WHERE last_seen_at < NOW() + ($1 * INTERVAL '1 day') AND is_revoked = false
		ORDER BY last_seen_at ASC
		LIMIT 100
	`, -days)
	if err != nil {
		return nil, fmt.Errorf("stale devices: %w", err)
	}
	defer rows.Close()

	var devices []AdminStaleDevice
	for rows.Next() {
		var sd AdminStaleDevice
		var lastSeen time.Time
		if err := rows.Scan(&sd.ID, &sd.UserID, &sd.Name, &lastSeen, &sd.IsRevoked); err != nil {
			return nil, fmt.Errorf("scan stale device: %w", err)
		}
		sd.LastSeenAt = lastSeen.Format(time.RFC3339)
		devices = append(devices, sd)
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

// Admin detail types for management endpoints.

type AdminDeviceDetail struct {
	ID          string `json:"id"`
	UserID      string `json:"userId"`
	UserEmail   string `json:"userEmail"`
	Name        string `json:"name"`
	Platform    string `json:"platform"`
	IsOnline    bool   `json:"isOnline"`
	IsRevoked   bool   `json:"isRevoked"`
	PrivacyMode string `json:"privacyMode"`
	E2EEEnabled bool   `json:"e2eeEnabled"`
	LastSeenAt  string `json:"lastSeenAt"`
	CreatedAt   string `json:"createdAt"`
}

type AdminSessionDetail struct {
	ID          string `json:"id"`
	UserID      string `json:"userId"`
	UserEmail   string `json:"userEmail"`
	DeviceID    string `json:"deviceId"`
	ProjectName string `json:"-"`
	ProjectPath string `json:"-"`
	GitBranch   string `json:"-"`
	CWD         string `json:"-"`
	Status      string `json:"status"`
	StartedAt   string `json:"startedAt"`
	UpdatedAt   string `json:"updatedAt"`
	TokensIn    int64  `json:"tokensIn"`
	TokensOut   int64  `json:"tokensOut"`
	TurnCount   int    `json:"turnCount"`
	Description string `json:"-"`
}

type AdminCommandDetail struct {
	ID        string `json:"id"`
	SessionID string `json:"sessionId"`
	UserID    string `json:"userId"`
	UserEmail string `json:"userEmail"`
	Type      string `json:"type"`
	Status    string `json:"status"`
	Prompt    string `json:"-"`
	CreatedAt string `json:"createdAt"`
	UpdatedAt string `json:"updatedAt"`
}

// AdminGetUserDetail returns user info, their devices, and recent sessions.
func AdminGetUserDetail(d *sql.DB, userID string) (*AdminUser, []AdminDeviceDetail, []AdminSessionDetail, error) {
	// Get user info.
	var user AdminUser
	var createdAt time.Time
	err := d.QueryRow(`
		SELECT u.id, u.email, u.display_name, u.subscription_tier,
			CASE
				WHEN u.apple_user_id IS NOT NULL AND u.apple_user_id != '' THEN 'apple'
				WHEN u.password_hash IS NOT NULL AND u.password_hash != '' THEN 'email'
				ELSE 'unknown'
			END as auth_method,
			COALESCE(u.email_verified, true) as email_verified,
			(SELECT COUNT(*) FROM devices WHERE user_id = u.id AND is_revoked = false) as device_count,
			(SELECT COUNT(*) FROM sessions WHERE user_id = u.id) as session_count,
			u.created_at
		FROM users u WHERE u.id = $1
	`, userID).Scan(&user.ID, &user.Email, &user.DisplayName, &user.SubscriptionTier,
		&user.AuthMethod, &user.EmailVerified, &user.DeviceCount, &user.SessionCount, &createdAt)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("get user detail: %w", err)
	}
	user.CreatedAt = createdAt.Format(time.RFC3339)

	// Get devices.
	devRows, err := d.Query(`
		SELECT d.id, d.user_id, COALESCE(u.email, ''), d.name,
			COALESCE(d.system_info, ''),
			d.is_online, d.is_revoked, d.privacy_mode,
			CASE WHEN d.key_agreement_public_key IS NOT NULL AND d.key_agreement_public_key != '' THEN true ELSE false END,
			d.last_seen_at, d.enrolled_at
		FROM devices d
		LEFT JOIN users u ON d.user_id = u.id
		WHERE d.user_id = $1
		ORDER BY d.enrolled_at DESC
	`, userID)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("get user devices: %w", err)
	}
	defer devRows.Close()

	var devices []AdminDeviceDetail
	for devRows.Next() {
		var dev AdminDeviceDetail
		var lastSeen, enrolled time.Time
		if err := devRows.Scan(&dev.ID, &dev.UserID, &dev.UserEmail, &dev.Name,
			&dev.Platform, &dev.IsOnline, &dev.IsRevoked, &dev.PrivacyMode,
			&dev.E2EEEnabled, &lastSeen, &enrolled); err != nil {
			return nil, nil, nil, fmt.Errorf("scan user device: %w", err)
		}
		dev.LastSeenAt = lastSeen.Format(time.RFC3339)
		dev.CreatedAt = enrolled.Format(time.RFC3339)
		devices = append(devices, dev)
	}

	// Get recent 20 sessions.
	sessRows, err := d.Query(`
		SELECT s.id, s.user_id, COALESCE(u.email, ''), s.device_id,
			s.project_path, s.git_branch, s.cwd, s.status,
			s.started_at, s.updated_at, s.tokens_in, s.tokens_out, s.turn_count, s.description
		FROM sessions s
		LEFT JOIN users u ON s.user_id = u.id
		WHERE s.user_id = $1
		ORDER BY s.updated_at DESC LIMIT 20
	`, userID)
	if err != nil {
		return nil, nil, nil, fmt.Errorf("get user sessions: %w", err)
	}
	defer sessRows.Close()

	var sessions []AdminSessionDetail
	for sessRows.Next() {
		var sess AdminSessionDetail
		var startedAt, updatedAt time.Time
		if err := sessRows.Scan(&sess.ID, &sess.UserID, &sess.UserEmail, &sess.DeviceID,
			&sess.ProjectPath, &sess.GitBranch, &sess.CWD, &sess.Status,
			&startedAt, &updatedAt, &sess.TokensIn, &sess.TokensOut, &sess.TurnCount, &sess.Description); err != nil {
			return nil, nil, nil, fmt.Errorf("scan user session: %w", err)
		}
		sess.StartedAt = startedAt.Format(time.RFC3339)
		sess.UpdatedAt = updatedAt.Format(time.RFC3339)
		sessions = append(sessions, sess)
	}

	return &user, devices, sessions, nil
}

// AdminListDevices returns a paginated device list with user email.
func AdminListDevices(d *sql.DB, search string, limit, offset int) ([]AdminDeviceDetail, int, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}

	var total int
	var countQuery string
	var countArgs []interface{}
	if search != "" {
		countQuery = "SELECT COUNT(*) FROM devices d LEFT JOIN users u ON d.user_id = u.id WHERE d.name ILIKE $1 OR u.email ILIKE $2"
		pattern := "%" + search + "%"
		countArgs = []interface{}{pattern, pattern}
	} else {
		countQuery = "SELECT COUNT(*) FROM devices"
	}
	if err := d.QueryRow(countQuery, countArgs...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("count devices: %w", err)
	}

	var ph placeholderCounter
	query := `
		SELECT d.id, d.user_id, COALESCE(u.email, ''), d.name,
			COALESCE(d.system_info, ''),
			d.is_online, d.is_revoked, d.privacy_mode,
			CASE WHEN d.key_agreement_public_key IS NOT NULL AND d.key_agreement_public_key != '' THEN true ELSE false END,
			d.last_seen_at, d.enrolled_at
		FROM devices d
		LEFT JOIN users u ON d.user_id = u.id
	`
	var args []interface{}
	if search != "" {
		p1 := ph.Next()
		p2 := ph.Next()
		query += " WHERE d.name ILIKE " + p1 + " OR u.email ILIKE " + p2
		pattern := "%" + search + "%"
		args = append(args, pattern, pattern)
	}
	p3 := ph.Next()
	p4 := ph.Next()
	query += " ORDER BY d.enrolled_at DESC LIMIT " + p3 + " OFFSET " + p4
	args = append(args, limit, offset)

	rows, err := d.Query(query, args...)
	if err != nil {
		return nil, 0, fmt.Errorf("list devices: %w", err)
	}
	defer rows.Close()

	var devices []AdminDeviceDetail
	for rows.Next() {
		var dev AdminDeviceDetail
		var lastSeen, enrolled time.Time
		if err := rows.Scan(&dev.ID, &dev.UserID, &dev.UserEmail, &dev.Name,
			&dev.Platform, &dev.IsOnline, &dev.IsRevoked, &dev.PrivacyMode,
			&dev.E2EEEnabled, &lastSeen, &enrolled); err != nil {
			return nil, 0, fmt.Errorf("scan device: %w", err)
		}
		dev.LastSeenAt = lastSeen.Format(time.RFC3339)
		dev.CreatedAt = enrolled.Format(time.RFC3339)
		devices = append(devices, dev)
	}
	return devices, total, nil
}

// AdminListSessions returns a paginated session list with user email.
func AdminListSessions(d *sql.DB, status string, limit, offset int) ([]AdminSessionDetail, int, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}

	var total int
	var countWhere string
	var countArgs []interface{}
	if status != "" {
		countWhere = " WHERE s.status = $1"
		countArgs = []interface{}{status}
	}
	if err := d.QueryRow("SELECT COUNT(*) FROM sessions s"+countWhere, countArgs...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("count sessions: %w", err)
	}

	var ph placeholderCounter
	query := `
		SELECT s.id, s.user_id, COALESCE(u.email, ''), s.device_id,
			s.project_path, s.git_branch, s.cwd, s.status,
			s.started_at, s.updated_at, s.tokens_in, s.tokens_out, s.turn_count, s.description
		FROM sessions s
		LEFT JOIN users u ON s.user_id = u.id
	`
	var args []interface{}
	if status != "" {
		query += " WHERE s.status = " + ph.Next()
		args = append(args, status)
	}
	p1 := ph.Next()
	p2 := ph.Next()
	query += " ORDER BY s.updated_at DESC LIMIT " + p1 + " OFFSET " + p2
	args = append(args, limit, offset)

	rows, err := d.Query(query, args...)
	if err != nil {
		return nil, 0, fmt.Errorf("list sessions: %w", err)
	}
	defer rows.Close()

	var sessions []AdminSessionDetail
	for rows.Next() {
		var sess AdminSessionDetail
		var startedAt, updatedAt time.Time
		if err := rows.Scan(&sess.ID, &sess.UserID, &sess.UserEmail, &sess.DeviceID,
			&sess.ProjectPath, &sess.GitBranch, &sess.CWD, &sess.Status,
			&startedAt, &updatedAt, &sess.TokensIn, &sess.TokensOut, &sess.TurnCount, &sess.Description); err != nil {
			return nil, 0, fmt.Errorf("scan session: %w", err)
		}
		sess.StartedAt = startedAt.Format(time.RFC3339)
		sess.UpdatedAt = updatedAt.Format(time.RFC3339)
		sessions = append(sessions, sess)
	}
	return sessions, total, nil
}

// AdminListSessionCommands returns commands for a specific session.
func AdminListSessionCommands(d *sql.DB, sessionID string) ([]AdminCommandDetail, error) {
	rows, err := d.Query(`
		SELECT c.id, c.session_id, c.user_id, COALESCE(u.email, ''),
			CASE WHEN c.prompt_encrypted != '' THEN 'encrypted' ELSE 'continue' END as type,
			c.status, COALESCE(c.prompt_hash, ''), c.created_at, c.updated_at
		FROM commands c
		LEFT JOIN users u ON c.user_id = u.id
		WHERE c.session_id = $1
		ORDER BY c.created_at DESC
	`, sessionID)
	if err != nil {
		return nil, fmt.Errorf("list session commands: %w", err)
	}
	defer rows.Close()

	var commands []AdminCommandDetail
	for rows.Next() {
		var cmd AdminCommandDetail
		if err := rows.Scan(&cmd.ID, &cmd.SessionID, &cmd.UserID, &cmd.UserEmail,
			&cmd.Type, &cmd.Status, &cmd.Prompt, &cmd.CreatedAt, &cmd.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scan session command: %w", err)
		}
		commands = append(commands, cmd)
	}
	return commands, nil
}

// AdminListCommands returns a paginated command list with user email.
func AdminListCommands(d *sql.DB, status string, limit, offset int) ([]AdminCommandDetail, int, error) {
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}

	var total int
	var countWhere string
	var countArgs []interface{}
	if status != "" {
		countWhere = " WHERE c.status = $1"
		countArgs = []interface{}{status}
	}
	if err := d.QueryRow("SELECT COUNT(*) FROM commands c"+countWhere, countArgs...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("count commands: %w", err)
	}

	var ph placeholderCounter
	query := `
		SELECT c.id, c.session_id, c.user_id, COALESCE(u.email, ''),
			CASE WHEN c.prompt_encrypted != '' THEN 'encrypted' ELSE 'continue' END as type,
			c.status, COALESCE(c.prompt_hash, ''), c.created_at, c.updated_at
		FROM commands c
		LEFT JOIN sessions s ON c.session_id = s.id
		LEFT JOIN users u ON c.user_id = u.id
	`
	var args []interface{}
	if status != "" {
		query += " WHERE c.status = " + ph.Next()
		args = append(args, status)
	}
	p1 := ph.Next()
	p2 := ph.Next()
	query += " ORDER BY c.created_at DESC LIMIT " + p1 + " OFFSET " + p2
	args = append(args, limit, offset)

	rows, err := d.Query(query, args...)
	if err != nil {
		return nil, 0, fmt.Errorf("list commands: %w", err)
	}
	defer rows.Close()

	var commands []AdminCommandDetail
	for rows.Next() {
		var cmd AdminCommandDetail
		if err := rows.Scan(&cmd.ID, &cmd.SessionID, &cmd.UserID, &cmd.UserEmail,
			&cmd.Type, &cmd.Status, &cmd.Prompt, &cmd.CreatedAt, &cmd.UpdatedAt); err != nil {
			return nil, 0, fmt.Errorf("scan command: %w", err)
		}
		commands = append(commands, cmd)
	}
	return commands, total, nil
}

// AdminRevokeUser sets a user's tier to "revoked" and revokes all their devices.
func AdminRevokeUser(d *sql.DB, userID string) error {
	if err := UpdateUserSubscription(d, userID, "revoked", "", "", nil); err != nil {
		return fmt.Errorf("revoke user subscription: %w", err)
	}

	// Revoke all devices.
	_, err := d.Exec("UPDATE devices SET is_revoked = true WHERE user_id = $1", userID)
	if err != nil {
		return fmt.Errorf("revoke user devices: %w", err)
	}

	// Revoke device keys for each device.
	rows, err := d.Query("SELECT id FROM devices WHERE user_id = $1", userID)
	if err != nil {
		return fmt.Errorf("list user devices for key revocation: %w", err)
	}
	defer rows.Close()

	for rows.Next() {
		var deviceID string
		if err := rows.Scan(&deviceID); err != nil {
			continue
		}
		_ = RevokeDeviceKeys(d, deviceID)
	}
	return nil
}

// AdminListAppLogs returns a paginated list of app logs with optional filters (all users).
func AdminListAppLogs(d *sql.DB, level, source, userID, email, subsystem string, limit, offset int) ([]AdminAppLog, int, error) {
	// Build WHERE clause with placeholder counter for count query.
	var phCount placeholderCounter
	whereCount := "1=1"
	argsCount := []interface{}{}
	needsJoin := false

	if level != "" {
		whereCount += " AND l.level = " + phCount.Next()
		argsCount = append(argsCount, level)
	}
	if source != "" {
		whereCount += " AND l.source = " + phCount.Next()
		argsCount = append(argsCount, source)
	}
	if userID != "" {
		whereCount += " AND l.user_id = " + phCount.Next()
		argsCount = append(argsCount, userID)
	}
	if email != "" {
		whereCount += " AND u.email ILIKE " + phCount.Next()
		argsCount = append(argsCount, "%"+email+"%")
		needsJoin = true
	}
	if subsystem != "" {
		whereCount += " AND l.subsystem = " + phCount.Next()
		argsCount = append(argsCount, subsystem)
	}

	var total int
	countJoin := ""
	if needsJoin {
		countJoin = " LEFT JOIN users u ON u.id = l.user_id"
	}
	err := d.QueryRow("SELECT COUNT(*) FROM app_logs l"+countJoin+" WHERE "+whereCount, argsCount...).Scan(&total)
	if err != nil {
		return nil, 0, fmt.Errorf("count app logs: %w", err)
	}

	// Build WHERE clause with separate placeholder counter for the main query.
	var phQuery placeholderCounter
	whereQuery := "1=1"
	args := []interface{}{}

	if level != "" {
		whereQuery += " AND l.level = " + phQuery.Next()
		args = append(args, level)
	}
	if source != "" {
		whereQuery += " AND l.source = " + phQuery.Next()
		args = append(args, source)
	}
	if userID != "" {
		whereQuery += " AND l.user_id = " + phQuery.Next()
		args = append(args, userID)
	}
	if email != "" {
		whereQuery += " AND u.email ILIKE " + phQuery.Next()
		args = append(args, "%"+email+"%")
	}
	if subsystem != "" {
		whereQuery += " AND l.subsystem = " + phQuery.Next()
		args = append(args, subsystem)
	}

	query := `
		SELECT l.id, l.user_id, COALESCE(u.email, ''), l.device_id, l.source, l.level,
		       l.subsystem, l.message, l.metadata, l.created_at
		FROM app_logs l
		LEFT JOIN users u ON u.id = l.user_id
		WHERE ` + whereQuery + `
		ORDER BY l.created_at DESC
		LIMIT ` + phQuery.Next() + ` OFFSET ` + phQuery.Next()
	args = append(args, limit, offset)

	rows, err := d.Query(query, args...)
	if err != nil {
		return nil, 0, fmt.Errorf("list app logs: %w", err)
	}
	defer rows.Close()

	var logs []AdminAppLog
	for rows.Next() {
		var e AdminAppLog
		if err := rows.Scan(&e.ID, &e.UserID, &e.UserEmail, &e.DeviceID, &e.Source,
			&e.Level, &e.Subsystem, &e.Message, &e.Metadata, &e.CreatedAt); err != nil {
			return nil, 0, fmt.Errorf("scan app log: %w", err)
		}
		logs = append(logs, e)
	}
	return logs, total, rows.Err()
}

// AdminListFeedback returns a paginated list of feedback entries with optional filters (all users).
func AdminListFeedback(d *sql.DB, category, userID string, limit, offset int) ([]AdminFeedbackEntry, int, error) {
	// Build WHERE clause with placeholder counter for count query.
	var phCount placeholderCounter
	whereCount := "1=1"
	argsCount := []interface{}{}

	if category != "" {
		whereCount += " AND f.category = " + phCount.Next()
		argsCount = append(argsCount, category)
	}
	if userID != "" {
		whereCount += " AND f.user_id = " + phCount.Next()
		argsCount = append(argsCount, userID)
	}

	var total int
	err := d.QueryRow("SELECT COUNT(*) FROM feedback f WHERE "+whereCount, argsCount...).Scan(&total)
	if err != nil {
		return nil, 0, fmt.Errorf("count feedback: %w", err)
	}

	// Build WHERE clause with separate placeholder counter for the main query.
	var phQuery placeholderCounter
	whereQuery := "1=1"
	args := []interface{}{}

	if category != "" {
		whereQuery += " AND f.category = " + phQuery.Next()
		args = append(args, category)
	}
	if userID != "" {
		whereQuery += " AND f.user_id = " + phQuery.Next()
		args = append(args, userID)
	}

	query := `
		SELECT f.id, f.user_id, COALESCE(u.email, ''), f.device_id, f.category,
		       f.message, f.app_version, f.platform, f.created_at
		FROM feedback f
		LEFT JOIN users u ON u.id = f.user_id
		WHERE ` + whereQuery + `
		ORDER BY f.created_at DESC
		LIMIT ` + phQuery.Next() + ` OFFSET ` + phQuery.Next()
	args = append(args, limit, offset)

	rows, err := d.Query(query, args...)
	if err != nil {
		return nil, 0, fmt.Errorf("list feedback: %w", err)
	}
	defer rows.Close()

	var entries []AdminFeedbackEntry
	for rows.Next() {
		var e AdminFeedbackEntry
		if err := rows.Scan(&e.ID, &e.UserID, &e.UserEmail, &e.DeviceID, &e.Category,
			&e.Message, &e.AppVersion, &e.Platform, &e.CreatedAt); err != nil {
			return nil, 0, fmt.Errorf("scan feedback: %w", err)
		}
		entries = append(entries, e)
	}
	return entries, total, rows.Err()
}
