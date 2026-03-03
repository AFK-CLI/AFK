package db

import (
	"database/sql"
	"fmt"
	"time"

	"github.com/AFK/afk-cloud/internal/model"
)

// Commands

func CreateCommand(database *sql.DB, cmd *model.Command) error {
	_, err := database.Exec(`
		INSERT INTO commands (id, session_id, user_id, device_id, prompt_hash, prompt_encrypted, nonce, status, created_at, updated_at, expires_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, cmd.ID, cmd.SessionID, cmd.UserID, cmd.DeviceID, cmd.PromptHash,
		cmd.PromptEncrypted, cmd.Nonce, cmd.Status, cmd.CreatedAt, cmd.UpdatedAt, cmd.ExpiresAt)
	if err != nil {
		return fmt.Errorf("create command: %w", err)
	}
	return nil
}

func UpdateCommandStatus(database *sql.DB, commandID, status string) error {
	now := time.Now().UTC().Format(time.RFC3339)
	_, err := database.Exec(`UPDATE commands SET status = ?, updated_at = ? WHERE id = ?`,
		status, now, commandID)
	if err != nil {
		return fmt.Errorf("update command status: %w", err)
	}
	return nil
}

func GetCommand(database *sql.DB, commandID string) (*model.Command, error) {
	cmd := &model.Command{}
	var promptEncrypted sql.NullString
	err := database.QueryRow(`
		SELECT id, session_id, user_id, device_id, prompt_hash, prompt_encrypted, nonce, status, created_at, updated_at, expires_at
		FROM commands WHERE id = ?
	`, commandID).Scan(&cmd.ID, &cmd.SessionID, &cmd.UserID, &cmd.DeviceID,
		&cmd.PromptHash, &promptEncrypted, &cmd.Nonce, &cmd.Status,
		&cmd.CreatedAt, &cmd.UpdatedAt, &cmd.ExpiresAt)
	if err != nil {
		return nil, fmt.Errorf("get command: %w", err)
	}
	if promptEncrypted.Valid {
		cmd.PromptEncrypted = promptEncrypted.String
	}
	return cmd, nil
}

// PurgeExpiredCommands deletes commands that have expired and are in a terminal
// or pending state. This prevents unbounded growth of the commands table.
func PurgeExpiredCommands(db *sql.DB, cutoff time.Time) (int64, error) {
	result, err := db.Exec(`
		DELETE FROM commands
		WHERE expires_at < ?
		  AND status IN ('pending', 'completed', 'failed', 'cancelled')
	`, cutoff)
	if err != nil {
		return 0, fmt.Errorf("purge expired commands: %w", err)
	}
	return result.RowsAffected()
}
