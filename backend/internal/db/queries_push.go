package db

import (
	"database/sql"
	"fmt"
	"time"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/model"
)

// Push Tokens

func UpsertPushToken(database *sql.DB, userID, deviceToken, platform, bundleID string) error {
	now := time.Now().UTC().Format(time.RFC3339)
	id := auth.GenerateID()
	_, err := database.Exec(`
		INSERT INTO push_tokens (id, user_id, device_token, platform, bundle_id, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(device_token) DO UPDATE SET
			user_id = excluded.user_id,
			platform = excluded.platform,
			bundle_id = excluded.bundle_id,
			updated_at = excluded.updated_at
	`, id, userID, deviceToken, platform, bundleID, now, now)
	if err != nil {
		return fmt.Errorf("upsert push token: %w", err)
	}
	return nil
}

func DeletePushToken(database *sql.DB, deviceToken string) error {
	_, err := database.Exec(`DELETE FROM push_tokens WHERE device_token = ?`, deviceToken)
	if err != nil {
		return fmt.Errorf("delete push token: %w", err)
	}
	return nil
}

func DeletePushTokenForUser(database *sql.DB, deviceToken, userID string) error {
	_, err := database.Exec(`DELETE FROM push_tokens WHERE device_token = ? AND user_id = ?`, deviceToken, userID)
	if err != nil {
		return fmt.Errorf("delete push token for user: %w", err)
	}
	return nil
}

func DeletePushTokenByToken(database *sql.DB, deviceToken string) error {
	return DeletePushToken(database, deviceToken)
}

func ListPushTokensByUser(database *sql.DB, userID string) ([]model.PushToken, error) {
	rows, err := database.Query(`
		SELECT id, user_id, device_token, platform, bundle_id, created_at, updated_at
		FROM push_tokens WHERE user_id = ?
		ORDER BY created_at DESC
	`, userID)
	if err != nil {
		return nil, fmt.Errorf("list push tokens: %w", err)
	}
	defer rows.Close()

	var tokens []model.PushToken
	for rows.Next() {
		var t model.PushToken
		if err := rows.Scan(&t.ID, &t.UserID, &t.DeviceToken, &t.Platform, &t.BundleID, &t.CreatedAt, &t.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scan push token: %w", err)
		}
		tokens = append(tokens, t)
	}
	return tokens, rows.Err()
}

// Push-to-Start Tokens

func UpsertPushToStartToken(db *sql.DB, userID, token string) error {
	now := time.Now().UTC().Format(time.RFC3339)
	_, err := db.Exec(`
		INSERT INTO push_to_start_tokens (user_id, token, created_at, updated_at)
		VALUES (?, ?, ?, ?)
		ON CONFLICT(user_id) DO UPDATE SET
			token = excluded.token,
			updated_at = excluded.updated_at
	`, userID, token, now, now)
	if err != nil {
		return fmt.Errorf("upsert push-to-start token: %w", err)
	}
	return nil
}

func GetPushToStartToken(db *sql.DB, userID string) (string, error) {
	var token string
	err := db.QueryRow(`SELECT token FROM push_to_start_tokens WHERE user_id = ?`, userID).Scan(&token)
	if err != nil {
		return "", fmt.Errorf("get push-to-start token: %w", err)
	}
	return token, nil
}

func DeletePushToStartToken(db *sql.DB, userID string) error {
	_, err := db.Exec(`DELETE FROM push_to_start_tokens WHERE user_id = ?`, userID)
	if err != nil {
		return fmt.Errorf("delete push-to-start token: %w", err)
	}
	return nil
}
