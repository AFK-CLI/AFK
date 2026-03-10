package db

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/model"
)

// BatchInsertAppLogs inserts multiple log entries in a single transaction.
func BatchInsertAppLogs(db *sql.DB, userID string, entries []model.AppLogEntry) error {
	tx, err := db.Begin()
	if err != nil {
		return fmt.Errorf("begin tx: %w", err)
	}
	defer tx.Rollback()

	stmt, err := tx.Prepare(`
		INSERT INTO app_logs (id, user_id, device_id, source, level, subsystem, message, metadata, created_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
	`)
	if err != nil {
		return fmt.Errorf("prepare insert: %w", err)
	}
	defer stmt.Close()

	now := time.Now().UTC().Format(time.RFC3339)
	for _, e := range entries {
		metadataJSON := "{}"
		if len(e.Metadata) > 0 {
			b, err := json.Marshal(e.Metadata)
			if err == nil {
				metadataJSON = string(b)
			}
		}
		_, err := stmt.Exec(auth.GenerateID(), userID, e.DeviceID, e.Source, e.Level, e.Subsystem, e.Message, metadataJSON, now)
		if err != nil {
			return fmt.Errorf("insert app log: %w", err)
		}
	}

	return tx.Commit()
}

// ListAppLogs returns app logs for a user with optional filters.
func ListAppLogs(db *sql.DB, userID string, level, deviceID, source, subsystem string, limit, offset int) ([]*model.AppLog, error) {
	query := `SELECT id, user_id, device_id, source, level, subsystem, message, metadata, created_at
		FROM app_logs WHERE user_id = $1`
	args := []interface{}{userID}
	argPos := 2

	if level != "" {
		query += fmt.Sprintf(" AND level = $%d", argPos)
		args = append(args, level)
		argPos++
	}
	if deviceID != "" {
		query += fmt.Sprintf(" AND device_id = $%d", argPos)
		args = append(args, deviceID)
		argPos++
	}
	if source != "" {
		query += fmt.Sprintf(" AND source = $%d", argPos)
		args = append(args, source)
		argPos++
	}
	if subsystem != "" {
		query += fmt.Sprintf(" AND subsystem = $%d", argPos)
		args = append(args, subsystem)
		argPos++
	}

	query += fmt.Sprintf(" ORDER BY created_at DESC LIMIT $%d OFFSET $%d", argPos, argPos+1)
	args = append(args, limit, offset)

	rows, err := db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("list app logs: %w", err)
	}
	defer rows.Close()

	var logs []*model.AppLog
	for rows.Next() {
		l := &model.AppLog{}
		err := rows.Scan(&l.ID, &l.UserID, &l.DeviceID, &l.Source, &l.Level, &l.Subsystem, &l.Message, &l.Metadata, &l.CreatedAt)
		if err != nil {
			return nil, fmt.Errorf("scan app log: %w", err)
		}
		logs = append(logs, l)
	}
	return logs, rows.Err()
}

// PurgeOldAppLogs deletes app log entries older than the given cutoff.
func PurgeOldAppLogs(db *sql.DB, cutoff time.Time) (int64, error) {
	result, err := db.Exec(`DELETE FROM app_logs WHERE created_at < $1`, cutoff)
	if err != nil {
		return 0, fmt.Errorf("purge old app logs: %w", err)
	}
	return result.RowsAffected()
}
