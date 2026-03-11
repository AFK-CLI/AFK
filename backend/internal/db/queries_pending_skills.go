package db

import (
	"database/sql"
	"time"

	"github.com/AFK/afk-cloud/internal/auth"
)

type PendingSkillInstall struct {
	ID               string
	TargetDeviceID   string
	SenderDeviceID   string
	UserID           string
	EncryptedPayload string
	CreatedAt        time.Time
}

func InsertPendingSkillInstall(db *sql.DB, targetDeviceID, senderDeviceID, userID, encryptedPayload string) (string, error) {
	id := auth.GenerateID()
	_, err := db.Exec(`
		INSERT INTO pending_skill_installs (id, target_device_id, sender_device_id, user_id, encrypted_payload)
		VALUES ($1, $2, $3, $4, $5)
	`, id, targetDeviceID, senderDeviceID, userID, encryptedPayload)
	return id, err
}

func ListPendingSkillInstalls(db *sql.DB, targetDeviceID string) ([]PendingSkillInstall, error) {
	rows, err := db.Query(`
		SELECT id, target_device_id, sender_device_id, user_id, encrypted_payload, created_at
		FROM pending_skill_installs
		WHERE target_device_id = $1
		ORDER BY created_at ASC
	`, targetDeviceID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var result []PendingSkillInstall
	for rows.Next() {
		var p PendingSkillInstall
		if err := rows.Scan(&p.ID, &p.TargetDeviceID, &p.SenderDeviceID, &p.UserID, &p.EncryptedPayload, &p.CreatedAt); err != nil {
			return nil, err
		}
		result = append(result, p)
	}
	return result, rows.Err()
}

func DeletePendingSkillInstall(db *sql.DB, id string) error {
	_, err := db.Exec(`DELETE FROM pending_skill_installs WHERE id = $1`, id)
	return err
}

func DeletePendingSkillInstallsByDevice(db *sql.DB, targetDeviceID string) error {
	_, err := db.Exec(`DELETE FROM pending_skill_installs WHERE target_device_id = $1`, targetDeviceID)
	return err
}
