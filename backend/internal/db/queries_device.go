package db

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"time"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/model"
)

// Devices

func CreateDevice(db *sql.DB, userID, name, publicKey, systemInfo, capabilities string) (*model.Device, error) {
	now := time.Now()
	id := auth.GenerateID()

	if capabilities == "" {
		capabilities = "[]"
	}

	_, err := db.Exec(`
		INSERT INTO devices (id, user_id, name, public_key, system_info, enrolled_at, last_seen_at, is_online, is_revoked, capabilities)
		VALUES ($1, $2, $3, $4, $5, $6, $7, FALSE, FALSE, $8)
	`, id, userID, name, publicKey, systemInfo, now, now, capabilities)
	if err != nil {
		return nil, fmt.Errorf("create device: %w", err)
	}

	return &model.Device{
		ID:           id,
		UserID:       userID,
		Name:         name,
		PublicKey:    publicKey,
		SystemInfo:   systemInfo,
		EnrolledAt:   now,
		LastSeenAt:   now,
		IsOnline:     false,
		IsRevoked:    false,
		PrivacyMode:  "telemetry_only",
		Capabilities: json.RawMessage(capabilities),
	}, nil
}

func ListDevices(db *sql.DB, userID string) ([]*model.Device, error) {
	rows, err := db.Query(`
		SELECT id, user_id, name, public_key, system_info, enrolled_at, last_seen_at, is_online, is_revoked, privacy_mode,
			key_agreement_public_key, key_version, capabilities
		FROM devices WHERE user_id = $1 AND is_revoked = FALSE
		ORDER BY enrolled_at DESC
	`, userID)
	if err != nil {
		return nil, fmt.Errorf("list devices: %w", err)
	}
	defer rows.Close()

	var devices []*model.Device
	for rows.Next() {
		d := &model.Device{}
		var kaPubKey sql.NullString
		var capStr string
		err := rows.Scan(&d.ID, &d.UserID, &d.Name, &d.PublicKey, &d.SystemInfo,
			&d.EnrolledAt, &d.LastSeenAt, &d.IsOnline, &d.IsRevoked, &d.PrivacyMode,
			&kaPubKey, &d.KeyVersion, &capStr)
		if err != nil {
			return nil, fmt.Errorf("scan device: %w", err)
		}
		if kaPubKey.Valid {
			d.KeyAgreementPublicKey = kaPubKey.String
		}
		d.Capabilities = json.RawMessage(capStr)
		devices = append(devices, d)
	}
	return devices, rows.Err()
}

// ReactivateDevice updates an existing device record, clears is_revoked, and refreshes metadata.
func ReactivateDevice(database *sql.DB, deviceID, name, publicKey, systemInfo, capabilities string) (*model.Device, error) {
	now := time.Now()
	if capabilities == "" {
		capabilities = "[]"
	}
	_, err := database.Exec(`
		UPDATE devices SET name = $1, public_key = $2, system_info = $3, is_revoked = FALSE, last_seen_at = $4, capabilities = $5
		WHERE id = $6
	`, name, publicKey, systemInfo, now, capabilities, deviceID)
	if err != nil {
		return nil, fmt.Errorf("reactivate device: %w", err)
	}
	return GetDevice(database, deviceID)
}

// FindDeviceByFingerprint finds an existing non-revoked device by user + name + system_info.
func FindDeviceByFingerprint(database *sql.DB, userID, name, systemInfo string) (*model.Device, error) {
	d := &model.Device{}
	var kaPubKey sql.NullString
	var capStr string
	err := database.QueryRow(`
		SELECT id, user_id, name, public_key, system_info, enrolled_at, last_seen_at, is_online, is_revoked, privacy_mode,
			key_agreement_public_key, key_version, capabilities
		FROM devices WHERE user_id = $1 AND name = $2 AND system_info = $3 AND is_revoked = FALSE
		ORDER BY enrolled_at DESC LIMIT 1
	`, userID, name, systemInfo).Scan(&d.ID, &d.UserID, &d.Name, &d.PublicKey, &d.SystemInfo,
		&d.EnrolledAt, &d.LastSeenAt, &d.IsOnline, &d.IsRevoked, &d.PrivacyMode,
		&kaPubKey, &d.KeyVersion, &capStr)
	if err != nil {
		return nil, fmt.Errorf("find device by fingerprint: %w", err)
	}
	if kaPubKey.Valid {
		d.KeyAgreementPublicKey = kaPubKey.String
	}
	d.Capabilities = json.RawMessage(capStr)
	return d, nil
}

func DeleteDevice(db *sql.DB, deviceID, userID string) error {
	res, err := db.Exec(`UPDATE devices SET is_revoked = TRUE WHERE id = $1 AND user_id = $2`, deviceID, userID)
	if err != nil {
		return fmt.Errorf("delete device: %w", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return fmt.Errorf("device not found")
	}
	return nil
}

// ResetAllDevicesOffline marks all devices as offline. Call on server startup
// since no WS connections survive a restart.
func ResetAllDevicesOffline(db *sql.DB) error {
	_, err := db.Exec(`UPDATE devices SET is_online = FALSE`)
	return err
}

func UpdateDeviceStatus(db *sql.DB, deviceID string, isOnline bool, lastSeenAt time.Time) error {
	_, err := db.Exec(`UPDATE devices SET is_online = $1, last_seen_at = $2 WHERE id = $3`,
		isOnline, lastSeenAt, deviceID)
	if err != nil {
		return fmt.Errorf("update device status: %w", err)
	}
	return nil
}

func GetDevice(db *sql.DB, deviceID string) (*model.Device, error) {
	d := &model.Device{}
	var kaPubKey sql.NullString
	var capStr string
	err := db.QueryRow(`
		SELECT id, user_id, name, public_key, system_info, enrolled_at, last_seen_at, is_online, is_revoked, privacy_mode,
			key_agreement_public_key, key_version, capabilities
		FROM devices WHERE id = $1
	`, deviceID).Scan(&d.ID, &d.UserID, &d.Name, &d.PublicKey, &d.SystemInfo,
		&d.EnrolledAt, &d.LastSeenAt, &d.IsOnline, &d.IsRevoked, &d.PrivacyMode,
		&kaPubKey, &d.KeyVersion, &capStr)
	if err != nil {
		return nil, fmt.Errorf("get device: %w", err)
	}
	if kaPubKey.Valid {
		d.KeyAgreementPublicKey = kaPubKey.String
	}
	d.Capabilities = json.RawMessage(capStr)
	return d, nil
}

func CountActiveDevicesByType(db *sql.DB, userID string) (agentCount, iosCount int, err error) {
	err = db.QueryRow(`
		SELECT
			COUNT(CASE WHEN system_info NOT LIKE 'iOS%' THEN 1 END),
			COUNT(CASE WHEN system_info LIKE 'iOS%' THEN 1 END)
		FROM devices WHERE user_id = $1 AND is_revoked = FALSE
	`, userID).Scan(&agentCount, &iosCount)
	if err != nil {
		return 0, 0, fmt.Errorf("count active devices by type: %w", err)
	}
	return agentCount, iosCount, nil
}

// Device Key Agreement

func UpdateDeviceKeyAgreement(db *sql.DB, deviceID, publicKey string, version int) error {
	_, err := db.Exec(`UPDATE devices SET key_agreement_public_key = $1, key_version = $2 WHERE id = $3`,
		publicKey, version, deviceID)
	if err != nil {
		return fmt.Errorf("update device key agreement: %w", err)
	}
	return nil
}

func InsertDeviceKey(db *sql.DB, key *model.DeviceKey) error {
	if key.ID == "" {
		key.ID = auth.GenerateID()
	}
	now := time.Now().UTC().Format(time.RFC3339)
	_, err := db.Exec(`
		INSERT INTO device_keys (id, device_id, key_type, public_key, version, active, created_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
	`, key.ID, key.DeviceID, key.KeyType, key.PublicKey, key.Version, key.Active, now)
	if err != nil {
		return fmt.Errorf("insert device key: %w", err)
	}
	return nil
}

func RevokeDeviceKeys(db *sql.DB, deviceID string) error {
	now := time.Now().UTC().Format(time.RFC3339)
	_, err := db.Exec(`UPDATE device_keys SET active = FALSE, revoked_at = $1 WHERE device_id = $2 AND active = TRUE`,
		now, deviceID)
	if err != nil {
		return fmt.Errorf("revoke device keys: %w", err)
	}
	return nil
}

func GetActiveDeviceKey(db *sql.DB, deviceID, keyType string) (*model.DeviceKey, error) {
	k := &model.DeviceKey{}
	var revokedAt sql.NullString
	err := db.QueryRow(`
		SELECT id, device_id, key_type, public_key, version, active, created_at, revoked_at
		FROM device_keys WHERE device_id = $1 AND key_type = $2 AND active = TRUE
		ORDER BY version DESC LIMIT 1
	`, deviceID, keyType).Scan(&k.ID, &k.DeviceID, &k.KeyType, &k.PublicKey, &k.Version, &k.Active, &k.CreatedAt, &revokedAt)
	if err != nil {
		return nil, fmt.Errorf("get active device key: %w", err)
	}
	if revokedAt.Valid {
		k.RevokedAt = &revokedAt.String
	}
	return k, nil
}

// GetDeviceKeyByVersion returns a historical device key by version.
func GetDeviceKeyByVersion(db *sql.DB, deviceID string, version int) (*model.DeviceKey, error) {
	k := &model.DeviceKey{}
	var revokedAt sql.NullString
	err := db.QueryRow(`
		SELECT id, device_id, key_type, public_key, version, active, created_at, revoked_at
		FROM device_keys WHERE device_id = $1 AND version = $2
		ORDER BY created_at DESC LIMIT 1
	`, deviceID, version).Scan(&k.ID, &k.DeviceID, &k.KeyType, &k.PublicKey, &k.Version, &k.Active, &k.CreatedAt, &revokedAt)
	if err != nil {
		return nil, fmt.Errorf("get device key by version: %w", err)
	}
	if revokedAt.Valid {
		k.RevokedAt = &revokedAt.String
	}
	return k, nil
}

// GetPeerKeyAgreementKey returns the key_agreement public key for a peer device belonging to the same user.
// Used by one device to get another device's public key for ECDH.
func GetPeerKeyAgreementKey(db *sql.DB, userID, peerDeviceID string) (string, error) {
	var pubKey sql.NullString
	err := db.QueryRow(`
		SELECT key_agreement_public_key FROM devices
		WHERE id = $1 AND user_id = $2 AND is_revoked = FALSE AND key_agreement_public_key IS NOT NULL
	`, peerDeviceID, userID).Scan(&pubKey)
	if err != nil {
		return "", fmt.Errorf("get peer key agreement key: %w", err)
	}
	if !pubKey.Valid || pubKey.String == "" {
		return "", fmt.Errorf("peer device has no key agreement key")
	}
	return pubKey.String, nil
}

// Privacy Mode

func UpdateDevicePrivacyMode(db *sql.DB, deviceID, privacyMode string) error {
	_, err := db.Exec(`UPDATE devices SET privacy_mode = $1 WHERE id = $2`, privacyMode, deviceID)
	if err != nil {
		return fmt.Errorf("update device privacy mode: %w", err)
	}
	return nil
}

func GetDevicePrivacyMode(db *sql.DB, deviceID string) (string, error) {
	var mode string
	err := db.QueryRow(`SELECT privacy_mode FROM devices WHERE id = $1`, deviceID).Scan(&mode)
	if err != nil {
		return "", fmt.Errorf("get device privacy mode: %w", err)
	}
	return mode, nil
}
