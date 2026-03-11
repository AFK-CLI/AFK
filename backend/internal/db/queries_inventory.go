package db

import (
	"database/sql"
	"fmt"
	"time"
)

// DeviceInventoryRow represents a single device's inventory with device metadata.
type DeviceInventoryRow struct {
	DeviceID      string    `json:"deviceId"`
	DeviceName    string    `json:"deviceName"`
	IsOnline      bool      `json:"isOnline"`
	InventoryJSON string    `json:"inventory"`
	ContentHash   string    `json:"contentHash"`
	UpdatedAt     time.Time `json:"updatedAt"`
}

// UpsertDeviceInventory inserts or updates a device's inventory.
func UpsertDeviceInventory(db *sql.DB, deviceID, userID, inventoryJSON, hash string) error {
	_, err := db.Exec(`
		INSERT INTO device_inventory (device_id, user_id, inventory, content_hash, updated_at)
		VALUES ($1, $2, $3::jsonb, $4, NOW())
		ON CONFLICT (device_id) DO UPDATE SET
			inventory = EXCLUDED.inventory,
			content_hash = EXCLUDED.content_hash,
			updated_at = NOW()
	`, deviceID, userID, inventoryJSON, hash)
	if err != nil {
		return fmt.Errorf("upsert device inventory: %w", err)
	}
	return nil
}

// GetDeviceInventory returns the inventory for a single device.
func GetDeviceInventory(db *sql.DB, deviceID string) (inventoryJSON string, hash string, updatedAt time.Time, err error) {
	err = db.QueryRow(`
		SELECT inventory::text, content_hash, updated_at
		FROM device_inventory WHERE device_id = $1
	`, deviceID).Scan(&inventoryJSON, &hash, &updatedAt)
	if err != nil {
		return "", "", time.Time{}, fmt.Errorf("get device inventory: %w", err)
	}
	return inventoryJSON, hash, updatedAt, nil
}

// ListUserInventory returns the inventory for all of a user's devices, joined with device metadata.
func ListUserInventory(db *sql.DB, userID string) ([]DeviceInventoryRow, error) {
	rows, err := db.Query(`
		SELECT di.device_id, d.name, d.is_online, di.inventory::text, di.content_hash, di.updated_at
		FROM device_inventory di
		JOIN devices d ON d.id = di.device_id
		WHERE di.user_id = $1 AND d.is_revoked = FALSE
		ORDER BY di.updated_at DESC
	`, userID)
	if err != nil {
		return nil, fmt.Errorf("list user inventory: %w", err)
	}
	defer rows.Close()

	var result []DeviceInventoryRow
	for rows.Next() {
		var row DeviceInventoryRow
		if err := rows.Scan(&row.DeviceID, &row.DeviceName, &row.IsOnline, &row.InventoryJSON, &row.ContentHash, &row.UpdatedAt); err != nil {
			return nil, fmt.Errorf("scan device inventory row: %w", err)
		}
		result = append(result, row)
	}
	return result, rows.Err()
}

// DeleteDeviceInventory removes inventory data for a device.
func DeleteDeviceInventory(db *sql.DB, deviceID string) error {
	_, err := db.Exec(`DELETE FROM device_inventory WHERE device_id = $1`, deviceID)
	if err != nil {
		return fmt.Errorf("delete device inventory: %w", err)
	}
	return nil
}
