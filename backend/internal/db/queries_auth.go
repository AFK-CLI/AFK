package db

import (
	"database/sql"
	"fmt"
	"time"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/model"
)

// Users

func UpsertUser(db *sql.DB, appleUserID, email, displayName string) (*model.User, error) {
	now := time.Now()
	id := auth.GenerateID()

	_, err := db.Exec(`
		INSERT INTO users (id, apple_user_id, email, display_name, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT(apple_user_id) DO UPDATE SET
			email = excluded.email,
			display_name = CASE WHEN excluded.display_name = '' THEN users.display_name ELSE excluded.display_name END,
			updated_at = excluded.updated_at
	`, id, appleUserID, email, displayName, now, now)
	if err != nil {
		return nil, fmt.Errorf("upsert user: %w", err)
	}

	return GetUserByAppleID(db, appleUserID)
}

func GetUserByAppleID(db *sql.DB, appleUserID string) (*model.User, error) {
	u := &model.User{}
	var appleID sql.NullString
	var subscriptionExpiresAt sql.NullTime
	err := db.QueryRow(`
		SELECT id, apple_user_id, email, display_name, subscription_tier, subscription_expires_at, created_at, updated_at
		FROM users WHERE apple_user_id = $1
	`, appleUserID).Scan(&u.ID, &appleID, &u.Email, &u.DisplayName, &u.SubscriptionTier, &subscriptionExpiresAt, &u.CreatedAt, &u.UpdatedAt)
	if err != nil {
		return nil, fmt.Errorf("get user by apple id: %w", err)
	}
	if appleID.Valid {
		u.AppleUserID = appleID.String
	}
	if subscriptionExpiresAt.Valid {
		u.SubscriptionExpiresAt = &subscriptionExpiresAt.Time
	}
	return u, nil
}

func GetUser(db *sql.DB, userID string) (*model.User, error) {
	u := &model.User{}
	var appleUserID sql.NullString
	var subscriptionExpiresAt sql.NullTime
	err := db.QueryRow(`
		SELECT id, apple_user_id, email, display_name, subscription_tier, subscription_expires_at, created_at, updated_at
		FROM users WHERE id = $1
	`, userID).Scan(&u.ID, &appleUserID, &u.Email, &u.DisplayName, &u.SubscriptionTier, &subscriptionExpiresAt, &u.CreatedAt, &u.UpdatedAt)
	if err != nil {
		return nil, fmt.Errorf("get user: %w", err)
	}
	if appleUserID.Valid {
		u.AppleUserID = appleUserID.String
	}
	if subscriptionExpiresAt.Valid {
		u.SubscriptionExpiresAt = &subscriptionExpiresAt.Time
	}
	return u, nil
}

// Email/password users

func CreateEmailUser(db *sql.DB, email, displayName, passwordHash string) (*model.User, error) {
	now := time.Now()
	id := auth.GenerateID()

	_, err := db.Exec(`
		INSERT INTO users (id, apple_user_id, email, display_name, password_hash, email_verified, created_at, updated_at)
		VALUES ($1, NULL, $2, $3, $4, FALSE, $5, $6)
	`, id, email, displayName, passwordHash, now, now)
	if err != nil {
		return nil, fmt.Errorf("create email user: %w", err)
	}

	return &model.User{
		ID:               id,
		Email:            email,
		DisplayName:      displayName,
		SubscriptionTier: "free",
		CreatedAt:        now,
		UpdatedAt:        now,
	}, nil
}

func GetUserByEmail(db *sql.DB, email string) (*model.User, error) {
	u := &model.User{}
	var appleUserID sql.NullString
	var subscriptionExpiresAt sql.NullTime
	err := db.QueryRow(`
		SELECT id, apple_user_id, email, display_name, subscription_tier, subscription_expires_at, created_at, updated_at
		FROM users WHERE email = $1 AND password_hash IS NOT NULL
	`, email).Scan(&u.ID, &appleUserID, &u.Email, &u.DisplayName, &u.SubscriptionTier, &subscriptionExpiresAt, &u.CreatedAt, &u.UpdatedAt)
	if err != nil {
		return nil, fmt.Errorf("get user by email: %w", err)
	}
	if appleUserID.Valid {
		u.AppleUserID = appleUserID.String
	}
	if subscriptionExpiresAt.Valid {
		u.SubscriptionExpiresAt = &subscriptionExpiresAt.Time
	}
	return u, nil
}

func GetPasswordHash(db *sql.DB, userID string) (string, error) {
	var hash sql.NullString
	err := db.QueryRow(`SELECT password_hash FROM users WHERE id = $1`, userID).Scan(&hash)
	if err != nil {
		return "", fmt.Errorf("get password hash: %w", err)
	}
	if !hash.Valid {
		return "", fmt.Errorf("no password set for user")
	}
	return hash.String, nil
}

func RecordLoginAttempt(db *sql.DB, email string, success bool, ip string) {
	db.Exec(`INSERT INTO login_attempts (email, success, ip_address) VALUES ($1, $2, $3)`, email, success, ip)
}

func CountRecentFailedAttempts(db *sql.DB, email string, window time.Duration) (int, error) {
	cutoff := time.Now().Add(-window)
	var count int
	err := db.QueryRow(`
		SELECT COUNT(*) FROM login_attempts WHERE email = $1 AND success = FALSE AND attempted_at > $2
	`, email, cutoff).Scan(&count)
	if err != nil {
		return 0, fmt.Errorf("count failed attempts: %w", err)
	}
	return count, nil
}

func CleanupOldLoginAttempts(db *sql.DB, olderThan time.Duration) {
	cutoff := time.Now().Add(-olderThan)
	db.Exec(`DELETE FROM login_attempts WHERE attempted_at < $1`, cutoff)
}

// Refresh Tokens

func StoreRefreshToken(db *sql.DB, userID, tokenHash, familyID string, expiresAt time.Time) error {
	id := auth.GenerateID()
	if familyID == "" {
		familyID = id
	}
	_, err := db.Exec(`
		INSERT INTO refresh_tokens (id, user_id, token_hash, family_id, expires_at, revoked)
		VALUES ($1, $2, $3, $4, $5, FALSE)
	`, id, userID, tokenHash, familyID, expiresAt)
	if err != nil {
		return fmt.Errorf("store refresh token: %w", err)
	}
	return nil
}

func ValidateRefreshToken(db *sql.DB, tokenHash string) (string, error) {
	var userID string
	var expiresAt time.Time
	var revoked bool
	err := db.QueryRow(`
		SELECT user_id, expires_at, revoked FROM refresh_tokens WHERE token_hash = $1
	`, tokenHash).Scan(&userID, &expiresAt, &revoked)
	if err != nil {
		return "", fmt.Errorf("validate refresh token: %w", err)
	}
	if revoked {
		return "", fmt.Errorf("refresh token revoked")
	}
	if time.Now().After(expiresAt) {
		return "", fmt.Errorf("refresh token expired")
	}
	return userID, nil
}

func RevokeRefreshToken(db *sql.DB, tokenHash string) error {
	_, err := db.Exec(`UPDATE refresh_tokens SET revoked = TRUE WHERE token_hash = $1`, tokenHash)
	if err != nil {
		return fmt.Errorf("revoke refresh token: %w", err)
	}
	return nil
}

// LookupRefreshToken returns the userID, familyID, and status flags for a hashed token.
func LookupRefreshToken(db *sql.DB, tokenHash string) (userID, familyID string, revoked bool, expired bool, err error) {
	var expiresAt time.Time
	err = db.QueryRow(`
		SELECT user_id, family_id, revoked, expires_at FROM refresh_tokens WHERE token_hash = $1
	`, tokenHash).Scan(&userID, &familyID, &revoked, &expiresAt)
	if err != nil {
		return "", "", false, false, fmt.Errorf("lookup refresh token: %w", err)
	}
	return userID, familyID, revoked, time.Now().After(expiresAt), nil
}

// RevokeRefreshTokenFamily revokes all tokens in a family (reuse detection).
func RevokeRefreshTokenFamily(db *sql.DB, familyID string) error {
	_, err := db.Exec(`UPDATE refresh_tokens SET revoked = TRUE WHERE family_id = $1`, familyID)
	if err != nil {
		return fmt.Errorf("revoke refresh token family: %w", err)
	}
	return nil
}

// PurgeExpiredRefreshTokens deletes revoked or expired tokens older than the grace period.
func PurgeExpiredRefreshTokens(db *sql.DB, graceCutoff time.Time) (int64, error) {
	result, err := db.Exec(`
		DELETE FROM refresh_tokens
		WHERE (revoked = TRUE OR expires_at < $1)
		  AND created_at < $2
	`, graceCutoff, graceCutoff)
	if err != nil {
		return 0, fmt.Errorf("purge expired refresh tokens: %w", err)
	}
	return result.RowsAffected()
}

// GetUserEmailByID returns just the email for a given user ID.
func GetUserEmailByID(db *sql.DB, userID string) (string, error) {
	var email string
	err := db.QueryRow(`SELECT email FROM users WHERE id = $1`, userID).Scan(&email)
	if err != nil {
		return "", fmt.Errorf("get user email: %w", err)
	}
	return email, nil
}

// Subscriptions

func UpdateUserSubscription(db *sql.DB, userID, tier, productID, originalTxID string, expiresAt *time.Time) error {
	_, err := db.Exec(`
		UPDATE users SET subscription_tier = $1, subscription_product_id = $2,
			subscription_original_transaction_id = $3, subscription_expires_at = $4,
			updated_at = CURRENT_TIMESTAMP
		WHERE id = $5
	`, tier, productID, originalTxID, expiresAt, userID)
	if err != nil {
		return fmt.Errorf("update user subscription: %w", err)
	}
	return nil
}

func GetUserByOriginalTransactionID(db *sql.DB, originalTxID string) (*model.User, error) {
	u := &model.User{}
	var appleUserID sql.NullString
	var subscriptionExpiresAt sql.NullTime
	err := db.QueryRow(`
		SELECT id, apple_user_id, email, display_name, subscription_tier, subscription_expires_at, created_at, updated_at
		FROM users WHERE subscription_original_transaction_id = $1
	`, originalTxID).Scan(&u.ID, &appleUserID, &u.Email, &u.DisplayName, &u.SubscriptionTier, &subscriptionExpiresAt, &u.CreatedAt, &u.UpdatedAt)
	if err != nil {
		return nil, fmt.Errorf("get user by original transaction id: %w", err)
	}
	if appleUserID.Valid {
		u.AppleUserID = appleUserID.String
	}
	if subscriptionExpiresAt.Valid {
		u.SubscriptionExpiresAt = &subscriptionExpiresAt.Time
	}
	return u, nil
}

func GetUserTier(db *sql.DB, userID string) (string, error) {
	var tier string
	err := db.QueryRow(`SELECT subscription_tier FROM users WHERE id = $1`, userID).Scan(&tier)
	if err != nil {
		return "", fmt.Errorf("get user tier: %w", err)
	}
	return tier, nil
}

// Passkey Credentials

type PasskeyCredential struct {
	ID              string
	UserID          string
	CredentialID    []byte
	PublicKey       []byte
	AttestationType string
	Transport       string
	SignCount       int
	AAGUID          []byte
	CloneWarning    bool
	BackupEligible  bool
	BackupState     bool
	FriendlyName    string
	CreatedAt       time.Time
	LastUsedAt      time.Time
}

func CreatePasskeyCredential(db *sql.DB, id, userID string, credentialID, publicKey []byte, attestationType, transport string, aaguid []byte, friendlyName string, backupEligible, backupState bool) error {
	_, err := db.Exec(`
		INSERT INTO passkey_credentials (id, user_id, credential_id, public_key, attestation_type, transport, aaguid, friendly_name, backup_eligible, backup_state)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
	`, id, userID, credentialID, publicKey, attestationType, transport, aaguid, friendlyName, backupEligible, backupState)
	if err != nil {
		return fmt.Errorf("create passkey credential: %w", err)
	}
	return nil
}

func GetPasskeyCredentials(db *sql.DB, userID string) ([]PasskeyCredential, error) {
	rows, err := db.Query(`
		SELECT id, user_id, credential_id, public_key, attestation_type, transport, sign_count, aaguid, clone_warning, backup_eligible, backup_state, friendly_name, created_at, last_used_at
		FROM passkey_credentials WHERE user_id = $1
	`, userID)
	if err != nil {
		return nil, fmt.Errorf("get passkey credentials: %w", err)
	}
	defer rows.Close()

	var creds []PasskeyCredential
	for rows.Next() {
		var c PasskeyCredential
		if err := rows.Scan(&c.ID, &c.UserID, &c.CredentialID, &c.PublicKey, &c.AttestationType, &c.Transport, &c.SignCount, &c.AAGUID, &c.CloneWarning, &c.BackupEligible, &c.BackupState, &c.FriendlyName, &c.CreatedAt, &c.LastUsedAt); err != nil {
			return nil, fmt.Errorf("scan passkey credential: %w", err)
		}
		creds = append(creds, c)
	}
	return creds, nil
}

func UpdatePasskeySignCount(db *sql.DB, credentialIDBase64 string, signCount int) error {
	_, err := db.Exec(`
		UPDATE passkey_credentials SET sign_count = $1, last_used_at = CURRENT_TIMESTAMP WHERE id = $2
	`, signCount, credentialIDBase64)
	if err != nil {
		return fmt.Errorf("update passkey sign count: %w", err)
	}
	return nil
}

// Email Verification

func CreateEmailVerification(db *sql.DB, userID, token string, expiresAt time.Time) error {
	_, err := db.Exec(`
		INSERT INTO email_verifications (token, user_id, expires_at)
		VALUES ($1, $2, $3)
	`, token, userID, expiresAt)
	if err != nil {
		return fmt.Errorf("create email verification: %w", err)
	}
	return nil
}

func VerifyEmailToken(db *sql.DB, token string) (string, error) {
	var userID string
	var expiresAt time.Time
	err := db.QueryRow(`
		SELECT user_id, expires_at FROM email_verifications WHERE token = $1
	`, token).Scan(&userID, &expiresAt)
	if err != nil {
		return "", fmt.Errorf("verify email token: %w", err)
	}
	if time.Now().After(expiresAt) {
		return "", fmt.Errorf("verification token expired")
	}
	return userID, nil
}

func SetEmailVerified(db *sql.DB, userID string) error {
	_, err := db.Exec(`UPDATE users SET email_verified = TRUE, updated_at = CURRENT_TIMESTAMP WHERE id = $1`, userID)
	if err != nil {
		return fmt.Errorf("set email verified: %w", err)
	}
	// Clean up used tokens for this user.
	db.Exec(`DELETE FROM email_verifications WHERE user_id = $1`, userID)
	return nil
}

func IsEmailVerified(db *sql.DB, userID string) (bool, error) {
	var verified bool
	err := db.QueryRow(`SELECT email_verified FROM users WHERE id = $1`, userID).Scan(&verified)
	if err != nil {
		return false, fmt.Errorf("check email verified: %w", err)
	}
	return verified, nil
}

func GetUserByPasskeyCredentialID(db *sql.DB, credentialID []byte) (*model.User, string, error) {
	var u model.User
	var appleUserID sql.NullString
	var subscriptionExpiresAt sql.NullTime
	var passkeyID string
	err := db.QueryRow(`
		SELECT u.id, u.apple_user_id, u.email, u.display_name, u.subscription_tier, u.subscription_expires_at, u.created_at, u.updated_at, pc.id
		FROM passkey_credentials pc
		JOIN users u ON u.id = pc.user_id
		WHERE pc.credential_id = $1
	`, credentialID).Scan(&u.ID, &appleUserID, &u.Email, &u.DisplayName, &u.SubscriptionTier, &subscriptionExpiresAt, &u.CreatedAt, &u.UpdatedAt, &passkeyID)
	if err != nil {
		return nil, "", fmt.Errorf("get user by passkey credential: %w", err)
	}
	if appleUserID.Valid {
		u.AppleUserID = appleUserID.String
	}
	if subscriptionExpiresAt.Valid {
		u.SubscriptionExpiresAt = &subscriptionExpiresAt.Time
	}
	return &u, passkeyID, nil
}
