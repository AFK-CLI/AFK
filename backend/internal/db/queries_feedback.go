package db

import (
	"database/sql"
	"fmt"
	"time"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/model"
)

// CreateFeedback inserts a new feedback entry.
func CreateFeedback(db *sql.DB, f *model.Feedback) error {
	if f.ID == "" {
		f.ID = auth.GenerateID()
	}
	if f.CreatedAt == "" {
		f.CreatedAt = time.Now().UTC().Format(time.RFC3339)
	}
	_, err := db.Exec(`
		INSERT INTO feedback (id, user_id, device_id, category, message, app_version, platform, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?)
	`, f.ID, f.UserID, f.DeviceID, f.Category, f.Message, f.AppVersion, f.Platform, f.CreatedAt)
	if err != nil {
		return fmt.Errorf("insert feedback: %w", err)
	}
	return nil
}

// ListFeedback returns feedback entries for a user, newest first.
func ListFeedback(db *sql.DB, userID string, limit, offset int) ([]*model.Feedback, error) {
	rows, err := db.Query(`
		SELECT id, user_id, device_id, category, message, app_version, platform, created_at
		FROM feedback WHERE user_id = ?
		ORDER BY created_at DESC LIMIT ? OFFSET ?
	`, userID, limit, offset)
	if err != nil {
		return nil, fmt.Errorf("list feedback: %w", err)
	}
	defer rows.Close()

	var entries []*model.Feedback
	for rows.Next() {
		f := &model.Feedback{}
		err := rows.Scan(&f.ID, &f.UserID, &f.DeviceID, &f.Category, &f.Message, &f.AppVersion, &f.Platform, &f.CreatedAt)
		if err != nil {
			return nil, fmt.Errorf("scan feedback: %w", err)
		}
		entries = append(entries, f)
	}
	return entries, rows.Err()
}
