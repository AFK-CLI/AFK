package db

import (
	"database/sql"
	"fmt"
	"time"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/model"
)

// Audit Log

func InsertAuditLog(db *sql.DB, entry *model.AuditLogEntry) error {
	if entry.ID == "" {
		entry.ID = auth.GenerateID()
	}
	if entry.CreatedAt == "" {
		entry.CreatedAt = time.Now().UTC().Format(time.RFC3339)
	}
	_, err := db.Exec(`
		INSERT INTO audit_log (id, user_id, device_id, action, details, content_hash, ip_address, created_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
	`, entry.ID, entry.UserID, entry.DeviceID, entry.Action, entry.Details,
		entry.ContentHash, entry.IPAddress, entry.CreatedAt)
	if err != nil {
		return fmt.Errorf("insert audit log: %w", err)
	}
	return nil
}

func ListAuditLog(db *sql.DB, userID string, limit, offset int) ([]*model.AuditLogEntry, error) {
	rows, err := db.Query(`
		SELECT id, user_id, device_id, action, details, content_hash, ip_address, created_at
		FROM audit_log WHERE user_id = $1
		ORDER BY created_at DESC LIMIT $2 OFFSET $3
	`, userID, limit, offset)
	if err != nil {
		return nil, fmt.Errorf("list audit log: %w", err)
	}
	defer rows.Close()

	var entries []*model.AuditLogEntry
	for rows.Next() {
		e := &model.AuditLogEntry{}
		var deviceID, contentHash, ipAddress sql.NullString
		err := rows.Scan(&e.ID, &e.UserID, &deviceID, &e.Action, &e.Details,
			&contentHash, &ipAddress, &e.CreatedAt)
		if err != nil {
			return nil, fmt.Errorf("scan audit log: %w", err)
		}
		if deviceID.Valid {
			e.DeviceID = deviceID.String
		}
		if contentHash.Valid {
			e.ContentHash = contentHash.String
		}
		if ipAddress.Valid {
			e.IPAddress = ipAddress.String
		}
		entries = append(entries, e)
	}
	return entries, rows.Err()
}

// PurgeOldAuditLogs deletes audit log entries older than the given cutoff.
func PurgeOldAuditLogs(db *sql.DB, cutoff time.Time) (int64, error) {
	result, err := db.Exec(`DELETE FROM audit_log WHERE created_at < $1`, cutoff)
	if err != nil {
		return 0, fmt.Errorf("purge old audit logs: %w", err)
	}
	return result.RowsAffected()
}
