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
		VALUES (?, ?, ?, ?, ?, ?)
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
		FROM users WHERE apple_user_id = ?
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
		FROM users WHERE id = ?
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
		INSERT INTO users (id, apple_user_id, email, display_name, password_hash, created_at, updated_at)
		VALUES (?, NULL, ?, ?, ?, ?, ?)
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
		FROM users WHERE email = ? AND password_hash IS NOT NULL
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
	err := db.QueryRow(`SELECT password_hash FROM users WHERE id = ?`, userID).Scan(&hash)
	if err != nil {
		return "", fmt.Errorf("get password hash: %w", err)
	}
	if !hash.Valid {
		return "", fmt.Errorf("no password set for user")
	}
	return hash.String, nil
}

func RecordLoginAttempt(db *sql.DB, email string, success bool, ip string) {
	s := 0
	if success {
		s = 1
	}
	db.Exec(`INSERT INTO login_attempts (email, success, ip_address) VALUES (?, ?, ?)`, email, s, ip)
}

func CountRecentFailedAttempts(db *sql.DB, email string, window time.Duration) (int, error) {
	cutoff := time.Now().Add(-window)
	var count int
	err := db.QueryRow(`
		SELECT COUNT(*) FROM login_attempts WHERE email = ? AND success = 0 AND attempted_at > ?
	`, email, cutoff).Scan(&count)
	if err != nil {
		return 0, fmt.Errorf("count failed attempts: %w", err)
	}
	return count, nil
}

func CleanupOldLoginAttempts(db *sql.DB, olderThan time.Duration) {
	cutoff := time.Now().Add(-olderThan)
	db.Exec(`DELETE FROM login_attempts WHERE attempted_at < ?`, cutoff)
}

// Refresh Tokens

func StoreRefreshToken(db *sql.DB, userID, tokenHash, familyID string, expiresAt time.Time) error {
	id := auth.GenerateID()
	if familyID == "" {
		familyID = id
	}
	_, err := db.Exec(`
		INSERT INTO refresh_tokens (id, user_id, token_hash, family_id, expires_at, revoked)
		VALUES (?, ?, ?, ?, ?, 0)
	`, id, userID, tokenHash, familyID, expiresAt)
	if err != nil {
		return fmt.Errorf("store refresh token: %w", err)
	}
	return nil
}

func ValidateRefreshToken(db *sql.DB, tokenHash string) (string, error) {
	var userID string
	var expiresAt time.Time
	var revoked int
	err := db.QueryRow(`
		SELECT user_id, expires_at, revoked FROM refresh_tokens WHERE token_hash = ?
	`, tokenHash).Scan(&userID, &expiresAt, &revoked)
	if err != nil {
		return "", fmt.Errorf("validate refresh token: %w", err)
	}
	if revoked != 0 {
		return "", fmt.Errorf("refresh token revoked")
	}
	if time.Now().After(expiresAt) {
		return "", fmt.Errorf("refresh token expired")
	}
	return userID, nil
}

func RevokeRefreshToken(db *sql.DB, tokenHash string) error {
	_, err := db.Exec(`UPDATE refresh_tokens SET revoked = 1 WHERE token_hash = ?`, tokenHash)
	if err != nil {
		return fmt.Errorf("revoke refresh token: %w", err)
	}
	return nil
}

// LookupRefreshToken returns the userID, familyID, and status flags for a hashed token.
func LookupRefreshToken(db *sql.DB, tokenHash string) (userID, familyID string, revoked bool, expired bool, err error) {
	var revokedInt int
	var expiresAt time.Time
	err = db.QueryRow(`
		SELECT user_id, family_id, revoked, expires_at FROM refresh_tokens WHERE token_hash = ?
	`, tokenHash).Scan(&userID, &familyID, &revokedInt, &expiresAt)
	if err != nil {
		return "", "", false, false, fmt.Errorf("lookup refresh token: %w", err)
	}
	return userID, familyID, revokedInt != 0, time.Now().After(expiresAt), nil
}

// RevokeRefreshTokenFamily revokes all tokens in a family (reuse detection).
func RevokeRefreshTokenFamily(db *sql.DB, familyID string) error {
	_, err := db.Exec(`UPDATE refresh_tokens SET revoked = 1 WHERE family_id = ?`, familyID)
	if err != nil {
		return fmt.Errorf("revoke refresh token family: %w", err)
	}
	return nil
}

// PurgeExpiredRefreshTokens deletes revoked or expired tokens older than the grace period.
func PurgeExpiredRefreshTokens(db *sql.DB, graceCutoff time.Time) (int64, error) {
	result, err := db.Exec(`
		DELETE FROM refresh_tokens
		WHERE (revoked = 1 OR expires_at < ?)
		  AND created_at < ?
	`, graceCutoff, graceCutoff)
	if err != nil {
		return 0, fmt.Errorf("purge expired refresh tokens: %w", err)
	}
	return result.RowsAffected()
}

// GetUserEmailByID returns just the email for a given user ID.
func GetUserEmailByID(db *sql.DB, userID string) (string, error) {
	var email string
	err := db.QueryRow(`SELECT email FROM users WHERE id = ?`, userID).Scan(&email)
	if err != nil {
		return "", fmt.Errorf("get user email: %w", err)
	}
	return email, nil
}

// Subscriptions

func UpdateUserSubscription(db *sql.DB, userID, tier, productID, originalTxID string, expiresAt *time.Time) error {
	_, err := db.Exec(`
		UPDATE users SET subscription_tier = ?, subscription_product_id = ?,
			subscription_original_transaction_id = ?, subscription_expires_at = ?,
			updated_at = CURRENT_TIMESTAMP
		WHERE id = ?
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
		FROM users WHERE subscription_original_transaction_id = ?
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
	err := db.QueryRow(`SELECT subscription_tier FROM users WHERE id = ?`, userID).Scan(&tier)
	if err != nil {
		return "", fmt.Errorf("get user tier: %w", err)
	}
	return tier, nil
}
