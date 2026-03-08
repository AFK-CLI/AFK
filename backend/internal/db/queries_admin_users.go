package db

import (
	"database/sql"
	"fmt"
	"time"

	"github.com/AFK/afk-cloud/internal/auth"
)

// AdminAccount represents an admin panel user (separate from regular users).
type AdminAccount struct {
	ID           string `json:"id"`
	Email        string `json:"email"`
	PasswordHash string `json:"-"`
	TOTPSecret   string `json:"-"`
	TOTPEnabled  bool   `json:"totpEnabled"`
	CreatedAt    string `json:"createdAt"`
	UpdatedAt    string `json:"updatedAt"`
}

func CreateAdminUser(db *sql.DB, email, passwordHash string) (*AdminAccount, error) {
	id := auth.GenerateID()
	now := time.Now().UTC().Format(time.RFC3339)
	_, err := db.Exec(`
		INSERT INTO admin_users (id, email, password_hash, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?)
	`, id, email, passwordHash, now, now)
	if err != nil {
		return nil, fmt.Errorf("create admin user: %w", err)
	}
	return &AdminAccount{
		ID:        id,
		Email:     email,
		CreatedAt: now,
		UpdatedAt: now,
	}, nil
}

func GetAdminUserByEmail(db *sql.DB, email string) (*AdminAccount, error) {
	u := &AdminAccount{}
	var totpEnabled int
	err := db.QueryRow(`
		SELECT id, email, password_hash, totp_secret, totp_enabled, created_at, updated_at
		FROM admin_users WHERE email = ?
	`, email).Scan(&u.ID, &u.Email, &u.PasswordHash, &u.TOTPSecret, &totpEnabled, &u.CreatedAt, &u.UpdatedAt)
	if err != nil {
		return nil, fmt.Errorf("get admin user by email: %w", err)
	}
	u.TOTPEnabled = totpEnabled != 0
	return u, nil
}

func GetAdminUserByID(db *sql.DB, id string) (*AdminAccount, error) {
	u := &AdminAccount{}
	var totpEnabled int
	err := db.QueryRow(`
		SELECT id, email, password_hash, totp_secret, totp_enabled, created_at, updated_at
		FROM admin_users WHERE id = ?
	`, id).Scan(&u.ID, &u.Email, &u.PasswordHash, &u.TOTPSecret, &totpEnabled, &u.CreatedAt, &u.UpdatedAt)
	if err != nil {
		return nil, fmt.Errorf("get admin user by id: %w", err)
	}
	u.TOTPEnabled = totpEnabled != 0
	return u, nil
}

func CountAdminUsers(db *sql.DB) (int, error) {
	var count int
	err := db.QueryRow(`SELECT COUNT(*) FROM admin_users`).Scan(&count)
	if err != nil {
		return 0, fmt.Errorf("count admin users: %w", err)
	}
	return count, nil
}

func SetAdminTOTPSecret(db *sql.DB, adminID, secret string) error {
	_, err := db.Exec(`
		UPDATE admin_users SET totp_secret = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?
	`, secret, adminID)
	if err != nil {
		return fmt.Errorf("set admin totp secret: %w", err)
	}
	return nil
}

func EnableAdminTOTP(db *sql.DB, adminID string) error {
	_, err := db.Exec(`
		UPDATE admin_users SET totp_enabled = 1, updated_at = CURRENT_TIMESTAMP WHERE id = ?
	`, adminID)
	if err != nil {
		return fmt.Errorf("enable admin totp: %w", err)
	}
	return nil
}

// Admin Passkey Credentials

type AdminPasskeyCredential struct {
	ID              string
	AdminUserID     string
	CredentialID    []byte
	PublicKey       []byte
	AttestationType string
	Transport       string
	AAGUID          []byte
	SignCount       int
	CloneWarning    int
	BackupEligible  bool
	BackupState     bool
	FriendlyName    string
	CreatedAt       time.Time
	LastUsedAt      time.Time
}

func CreateAdminPasskeyCredential(db *sql.DB, id, adminUserID string, credentialID, publicKey []byte, attestationType, transport string, aaguid []byte, friendlyName string, backupEligible, backupState bool) error {
	be, bs := 0, 0
	if backupEligible {
		be = 1
	}
	if backupState {
		bs = 1
	}
	_, err := db.Exec(`
		INSERT INTO admin_passkey_credentials (id, admin_user_id, credential_id, public_key, attestation_type, transport, aaguid, friendly_name, backup_eligible, backup_state)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
	`, id, adminUserID, credentialID, publicKey, attestationType, transport, aaguid, friendlyName, be, bs)
	if err != nil {
		return fmt.Errorf("create admin passkey credential: %w", err)
	}
	return nil
}

func GetAdminPasskeyCredentials(db *sql.DB, adminUserID string) ([]AdminPasskeyCredential, error) {
	rows, err := db.Query(`
		SELECT id, admin_user_id, credential_id, public_key, attestation_type, transport, sign_count, aaguid, clone_warning, backup_eligible, backup_state, friendly_name, created_at, last_used_at
		FROM admin_passkey_credentials WHERE admin_user_id = ?
	`, adminUserID)
	if err != nil {
		return nil, fmt.Errorf("get admin passkey credentials: %w", err)
	}
	defer rows.Close()

	var creds []AdminPasskeyCredential
	for rows.Next() {
		var c AdminPasskeyCredential
		var be, bs int
		if err := rows.Scan(&c.ID, &c.AdminUserID, &c.CredentialID, &c.PublicKey, &c.AttestationType, &c.Transport, &c.SignCount, &c.AAGUID, &c.CloneWarning, &be, &bs, &c.FriendlyName, &c.CreatedAt, &c.LastUsedAt); err != nil {
			return nil, fmt.Errorf("scan admin passkey credential: %w", err)
		}
		c.BackupEligible = be != 0
		c.BackupState = bs != 0
		creds = append(creds, c)
	}
	return creds, nil
}

func UpdateAdminPasskeySignCount(db *sql.DB, credentialID string, signCount int) error {
	_, err := db.Exec(`
		UPDATE admin_passkey_credentials SET sign_count = ?, last_used_at = CURRENT_TIMESTAMP WHERE id = ?
	`, signCount, credentialID)
	if err != nil {
		return fmt.Errorf("update admin passkey sign count: %w", err)
	}
	return nil
}

func GetAdminUserByPasskeyCredentialID(db *sql.DB, credentialID []byte) (*AdminAccount, string, error) {
	u := &AdminAccount{}
	var totpEnabled int
	var passkeyID string
	err := db.QueryRow(`
		SELECT a.id, a.email, a.password_hash, a.totp_secret, a.totp_enabled, a.created_at, a.updated_at, apc.id
		FROM admin_passkey_credentials apc
		JOIN admin_users a ON a.id = apc.admin_user_id
		WHERE apc.credential_id = ?
	`, credentialID).Scan(&u.ID, &u.Email, &u.PasswordHash, &u.TOTPSecret, &totpEnabled, &u.CreatedAt, &u.UpdatedAt, &passkeyID)
	if err != nil {
		return nil, "", fmt.Errorf("get admin user by passkey credential: %w", err)
	}
	u.TOTPEnabled = totpEnabled != 0
	return u, passkeyID, nil
}
