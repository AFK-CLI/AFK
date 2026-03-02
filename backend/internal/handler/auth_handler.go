package handler

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"net"
	"net/http"
	"net/mail"
	"strings"
	"time"

	"database/sql"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/model"
	"golang.org/x/crypto/bcrypt"
)

// sanitizeText strips HTML angle brackets to prevent stored XSS.
func sanitizeText(s string) string {
	r := strings.NewReplacer("<", "", ">", "")
	return r.Replace(s)
}

// maxAuthBodySize limits the request body for auth endpoints (1 MB).
const maxAuthBodySize = 1 << 20

// TODO: Password complexity rules — require at least one uppercase, lowercase, digit, or special char
// TODO: Email verification — send confirmation link before account is fully active
// TODO: Per-IP rate limiting — current rate limit is per-email only; add IP-based throttle for credential stuffing
// TODO: Passkey/WebAuthn support — ASAuthorizationPlatformPublicKeyCredentialProvider on iOS + WebAuthn endpoints

type AuthHandler struct {
	DB              *sql.DB
	JWTSecret       string
	AppleBundleIDs  []string
	RequireTLS      bool                   // reject password auth over plain HTTP
}

// requireTLS rejects requests that arrive over plain HTTP in production.
// Checks X-Forwarded-Proto (set by nginx/reverse proxy) or r.TLS.
func (h *AuthHandler) requireTLS(w http.ResponseWriter, r *http.Request) bool {
	if !h.RequireTLS {
		return true
	}
	if r.TLS != nil || r.Header.Get("X-Forwarded-Proto") == "https" {
		return true
	}
	writeError(w, "HTTPS required for authentication endpoints", http.StatusForbidden)
	return false
}

func (h *AuthHandler) HandleAppleAuth(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, maxAuthBodySize)
	var req model.AppleAuthRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if req.IdentityToken == "" {
		writeError(w, "identityToken is required", http.StatusBadRequest)
		return
	}

	claims, err := auth.VerifyIdentityToken(req.IdentityToken, h.AppleBundleIDs)
	if err != nil {
		slog.Warn("apple identity token verification failed", "error", err)
		writeError(w, "invalid identity token", http.StatusUnauthorized)
		return
	}

	user, err := db.UpsertUser(h.DB, claims.Subject, claims.Email, "")
	if err != nil {
		writeError(w, "failed to create user", http.StatusInternalServerError)
		return
	}

	tokenPair, err := auth.IssueTokenPair(user.ID, h.JWTSecret)
	if err != nil {
		writeError(w, "failed to issue tokens", http.StatusInternalServerError)
		return
	}

	// Store hashed refresh token (new family).
	hash := hashToken(tokenPair.RefreshToken)
	expiresAt := time.Now().Add(30 * 24 * time.Hour)
	if err := db.StoreRefreshToken(h.DB, user.ID, hash, "", expiresAt); err != nil {
		writeError(w, "failed to store refresh token", http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, model.AuthResponse{
		AccessToken:  tokenPair.AccessToken,
		RefreshToken: tokenPair.RefreshToken,
		ExpiresAt:    tokenPair.ExpiresAt,
		User:         user,
	})
}

func (h *AuthHandler) HandleRefresh(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, maxAuthBodySize)
	var req model.RefreshRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if req.RefreshToken == "" {
		writeError(w, "refreshToken is required", http.StatusBadRequest)
		return
	}

	// Validate JWT structure of refresh token.
	userID, err := auth.ValidateRefreshTokenJWT(req.RefreshToken, h.JWTSecret)
	if err != nil {
		writeError(w, "invalid refresh token", http.StatusUnauthorized)
		return
	}

	// Look up the hashed token with family tracking.
	hash := hashToken(req.RefreshToken)
	storedUserID, familyID, revoked, expired, err := db.LookupRefreshToken(h.DB, hash)
	if err != nil {
		writeError(w, "refresh token invalid or revoked", http.StatusUnauthorized)
		return
	}

	if storedUserID != userID {
		writeError(w, "token mismatch", http.StatusUnauthorized)
		return
	}

	// Reuse detection: if the token is already revoked, someone is replaying it.
	// Revoke the entire family to protect the user.
	if revoked {
		slog.Warn("refresh token reuse detected, revoking family", "user_id", userID, "family_id", familyID)
		_ = db.RevokeRefreshTokenFamily(h.DB, familyID)
		writeError(w, "refresh token reuse detected", http.StatusUnauthorized)
		return
	}

	if expired {
		writeError(w, "refresh token expired", http.StatusUnauthorized)
		return
	}

	// Revoke old token (rotation).
	_ = db.RevokeRefreshToken(h.DB, hash)

	// Issue new pair.
	tokenPair, err := auth.IssueTokenPair(userID, h.JWTSecret)
	if err != nil {
		writeError(w, "failed to issue tokens", http.StatusInternalServerError)
		return
	}

	// Store new hashed refresh token in the same family.
	newHash := hashToken(tokenPair.RefreshToken)
	expiresAt := time.Now().Add(30 * 24 * time.Hour)
	if err := db.StoreRefreshToken(h.DB, userID, newHash, familyID, expiresAt); err != nil {
		writeError(w, "failed to store refresh token", http.StatusInternalServerError)
		return
	}

	user, err := db.GetUser(h.DB, userID)
	if err != nil {
		writeError(w, "user not found", http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, model.AuthResponse{
		AccessToken:  tokenPair.AccessToken,
		RefreshToken: tokenPair.RefreshToken,
		ExpiresAt:    tokenPair.ExpiresAt,
		User:         user,
	})
}

// HandleEmailRegister creates a new email/password user account.
func (h *AuthHandler) HandleEmailRegister(w http.ResponseWriter, r *http.Request) {
	if !h.requireTLS(w, r) {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxAuthBodySize)
	var req model.EmailRegisterRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	// Validate email format.
	email := strings.ToLower(strings.TrimSpace(req.Email))
	if len(email) > 254 {
		writeError(w, "email too long (max 254 characters)", http.StatusBadRequest)
		return
	}
	if !isValidEmail(email) {
		writeError(w, "invalid email format", http.StatusBadRequest)
		return
	}

	// Validate password length (8 to 72; 72 is bcrypt max).
	if len(req.Password) < 8 || len(req.Password) > 72 {
		writeError(w, "password must be 8 to 72 characters", http.StatusBadRequest)
		return
	}

	// Check if email already registered. Return a generic error message
	// to prevent email enumeration (attacker cannot distinguish registered
	// vs unregistered emails from the response).
	if _, err := db.GetUserByEmail(h.DB, email); err == nil {
		writeError(w, "registration failed", http.StatusBadRequest)
		return
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), 12)
	if err != nil {
		writeError(w, "failed to hash password", http.StatusInternalServerError)
		return
	}

	displayName := sanitizeText(strings.TrimSpace(req.DisplayName))
	if len(displayName) > 100 {
		displayName = displayName[:100]
	}
	if displayName == "" {
		displayName = email
	}

	user, err := db.CreateEmailUser(h.DB, email, displayName, string(hash))
	if err != nil {
		writeError(w, "failed to create user", http.StatusInternalServerError)
		return
	}

	tokenPair, err := auth.IssueTokenPair(user.ID, h.JWTSecret)
	if err != nil {
		writeError(w, "failed to issue tokens", http.StatusInternalServerError)
		return
	}

	tokenHash := hashToken(tokenPair.RefreshToken)
	expiresAt := time.Now().Add(30 * 24 * time.Hour)
	if err := db.StoreRefreshToken(h.DB, user.ID, tokenHash, "", expiresAt); err != nil {
		writeError(w, "failed to store refresh token", http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusCreated, model.AuthResponse{
		AccessToken:  tokenPair.AccessToken,
		RefreshToken: tokenPair.RefreshToken,
		ExpiresAt:    tokenPair.ExpiresAt,
		User:         user,
	})
}

// HandleEmailLogin authenticates an email/password user.
func (h *AuthHandler) HandleEmailLogin(w http.ResponseWriter, r *http.Request) {
	if !h.requireTLS(w, r) {
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxAuthBodySize)
	var req model.EmailLoginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	email := strings.ToLower(strings.TrimSpace(req.Email))
	ip := truncateIP(r.RemoteAddr)

	// Rate limiting: max 5 failed attempts per IP+email composite key per 15 minutes.
	// Using IP+email prevents a remote attacker from locking out all IPs for an account.
	lockoutKey := ip + ":" + email
	failCount, _ := db.CountRecentFailedAttempts(h.DB, lockoutKey, 15*time.Minute)
	if failCount >= 5 {
		writeError(w, "too many login attempts, try again later", http.StatusTooManyRequests)
		return
	}

	user, err := db.GetUserByEmail(h.DB, email)
	if err != nil {
		db.RecordLoginAttempt(h.DB, lockoutKey, false, ip)
		writeError(w, "invalid email or password", http.StatusUnauthorized)
		return
	}

	storedHash, err := db.GetPasswordHash(h.DB, user.ID)
	if err != nil {
		db.RecordLoginAttempt(h.DB, lockoutKey, false, ip)
		writeError(w, "invalid email or password", http.StatusUnauthorized)
		return
	}

	if err := bcrypt.CompareHashAndPassword([]byte(storedHash), []byte(req.Password)); err != nil {
		db.RecordLoginAttempt(h.DB, lockoutKey, false, ip)
		writeError(w, "invalid email or password", http.StatusUnauthorized)
		return
	}

	db.RecordLoginAttempt(h.DB, lockoutKey, true, ip)

	tokenPair, err := auth.IssueTokenPair(user.ID, h.JWTSecret)
	if err != nil {
		writeError(w, "failed to issue tokens", http.StatusInternalServerError)
		return
	}

	tokenHash := hashToken(tokenPair.RefreshToken)
	expiresAt := time.Now().Add(30 * 24 * time.Hour)
	if err := db.StoreRefreshToken(h.DB, user.ID, tokenHash, "", expiresAt); err != nil {
		writeError(w, "failed to store refresh token", http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, model.AuthResponse{
		AccessToken:  tokenPair.AccessToken,
		RefreshToken: tokenPair.RefreshToken,
		ExpiresAt:    tokenPair.ExpiresAt,
		User:         user,
	})
}

// HandleLogout revokes a refresh token.
func (h *AuthHandler) HandleLogout(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, maxAuthBodySize)
	var req model.LogoutRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if req.RefreshToken != "" {
		hash := hashToken(req.RefreshToken)
		_ = db.RevokeRefreshToken(h.DB, hash)
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func isValidEmail(email string) bool {
	addr, err := mail.ParseAddress(email)
	if err != nil {
		return false
	}
	// Ensure ParseAddress did not extract a display name
	// (e.g. "Name <user@example.com>" should be rejected).
	if addr.Address != email {
		return false
	}
	// Require at least one dot in the domain part.
	parts := strings.SplitN(addr.Address, "@", 2)
	if len(parts) != 2 {
		return false
	}
	return strings.Contains(parts[1], ".")
}

// truncateIP masks an IP address for privacy: IPv4 to /24, IPv6 to /48.
// If the address includes a port, it is stripped first.
func truncateIP(addr string) string {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		host = addr
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return "invalid"
	}
	if v4 := ip.To4(); v4 != nil {
		// Zero the last octet (/24).
		v4[3] = 0
		return v4.String()
	}
	// IPv6: zero bytes 6..15 (/48).
	full := ip.To16()
	for i := 6; i < 16; i++ {
		full[i] = 0
	}
	return full.String()
}

func hashToken(token string) string {
	h := sha256.Sum256([]byte(token))
	return hex.EncodeToString(h[:])
}
