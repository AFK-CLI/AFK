package db

import (
	"database/sql"
	"fmt"
	"time"

	"github.com/AFK/afk-cloud/internal/model"
)

// Notification Preferences

func GetNotificationPrefs(database *sql.DB, userID string) (*model.NotificationPrefs, error) {
	var prefs model.NotificationPrefs
	var quietStart, quietEnd sql.NullString
	err := database.QueryRow(`
		SELECT user_id, permission_requests, session_errors, session_completions, ask_user, session_activity, quiet_hours_start, quiet_hours_end
		FROM notification_preferences WHERE user_id = $1
	`, userID).Scan(&prefs.UserID, &prefs.PermissionRequests, &prefs.SessionErrors, &prefs.SessionCompletions, &prefs.AskUser, &prefs.SessionActivity, &quietStart, &quietEnd)
	if err == sql.ErrNoRows {
		// Return defaults: all enabled except session activity (off by default).
		return &model.NotificationPrefs{
			UserID:             userID,
			PermissionRequests: true,
			SessionErrors:      true,
			SessionCompletions: true,
			AskUser:            true,
			SessionActivity:    false,
		}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("get notification prefs: %w", err)
	}
	if quietStart.Valid {
		prefs.QuietHoursStart = quietStart.String
	}
	if quietEnd.Valid {
		prefs.QuietHoursEnd = quietEnd.String
	}
	return &prefs, nil
}

func UpsertNotificationPrefs(database *sql.DB, userID string, prefs *model.NotificationPrefs) error {
	now := time.Now().UTC().Format(time.RFC3339)
	var quietStart, quietEnd *string
	if prefs.QuietHoursStart != "" {
		quietStart = &prefs.QuietHoursStart
	}
	if prefs.QuietHoursEnd != "" {
		quietEnd = &prefs.QuietHoursEnd
	}
	_, err := database.Exec(`
		INSERT INTO notification_preferences (user_id, permission_requests, session_errors, session_completions, ask_user, session_activity, quiet_hours_start, quiet_hours_end, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
		ON CONFLICT(user_id) DO UPDATE SET
			permission_requests = excluded.permission_requests,
			session_errors = excluded.session_errors,
			session_completions = excluded.session_completions,
			ask_user = excluded.ask_user,
			session_activity = excluded.session_activity,
			quiet_hours_start = excluded.quiet_hours_start,
			quiet_hours_end = excluded.quiet_hours_end,
			updated_at = excluded.updated_at
	`, userID,
		prefs.PermissionRequests,
		prefs.SessionErrors,
		prefs.SessionCompletions,
		prefs.AskUser,
		prefs.SessionActivity,
		quietStart, quietEnd, now, now)
	if err != nil {
		return fmt.Errorf("upsert notification prefs: %w", err)
	}
	return nil
}
