package handler

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
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

// Rate limiting constants for login attempts.
const (
	maxFailedPerIPEmail = 5
	maxFailedPerIP      = 20
	rateLimitWindow     = 15 * time.Minute
)

// dummyBcryptHash is a pre-computed bcrypt hash used for timing-safe comparison
// when a login attempt targets a non-existent user. This prevents timing
// side-channels that could reveal whether an email is registered.
var dummyBcryptHash []byte

func init() {
	// Generate a dummy hash at package init (cost 12 matches real user hashes).
	dummyBcryptHash, _ = bcrypt.GenerateFromPassword([]byte("dummy-password-for-timing"), 12)
}

// verificationEmailHTML is the styled HTML email template for email verification.
// Uses four %s placeholders: baseURL (for icon), href URL, href URL again, display URL.
const verificationEmailHTML = `<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>Verify your AFK account</title></head>
<body style="margin:0;padding:0;background-color:#0F2240;font-family:-apple-system,BlinkMacSystemFont,'SF Pro Display','Segoe UI',Roboto,Helvetica,Arial,sans-serif;-webkit-font-smoothing:antialiased;">
<table role="presentation" width="100%%" cellpadding="0" cellspacing="0" style="background-color:#0F2240;">
<tr><td align="center" style="padding:48px 20px 40px;">

<table role="presentation" width="100%%" cellpadding="0" cellspacing="0" style="max-width:480px;">

<!-- Logo -->
<tr><td align="center" style="padding:0 0 32px;">
<img src="%s/icon.png" alt="AFK" width="80" height="80" style="display:block;width:80px;height:80px;border-radius:20px;">
</td></tr>

<!-- Card -->
<tr><td style="background-color:#152a4a;border:1px solid #1e3a5f;border-radius:20px;overflow:hidden;">

<!-- Card content -->
<table role="presentation" width="100%%" cellpadding="0" cellspacing="0">

<!-- Title -->
<tr><td align="center" style="padding:36px 40px 0;">
<h1 style="margin:0;font-size:24px;font-weight:700;color:#ffffff;letter-spacing:-0.02em;">Verify your email</h1>
</td></tr>
<tr><td align="center" style="padding:8px 40px 0;">
<p style="margin:0;font-size:15px;color:#8899b3;line-height:1.5;">One more step to get started with AFK</p>
</td></tr>

<!-- Divider -->
<tr><td style="padding:28px 40px 0;">
<div style="height:1px;background-color:#1e3a5f;"></div>
</td></tr>

<!-- Body -->
<tr><td style="padding:24px 40px 0;">
<p style="margin:0;font-size:15px;color:#a0b4cc;line-height:1.7;">
Tap the button below to confirm your email address. This link will expire in 24 hours.
</p>
</td></tr>

<!-- CTA Button -->
<tr><td align="center" style="padding:28px 40px 0;">
<table role="presentation" cellpadding="0" cellspacing="0">
<tr><td style="border-radius:12px;background-color:#2664EB;">
<a href="%s" target="_blank" style="display:inline-block;padding:14px 44px;color:#ffffff;font-size:15px;font-weight:600;text-decoration:none;font-family:-apple-system,BlinkMacSystemFont,'SF Pro Display',sans-serif;letter-spacing:0.2px;">
Verify Email Address
</a>
</td></tr>
</table>
</td></tr>

<!-- Fallback link -->
<tr><td style="padding:24px 40px 0;">
<p style="margin:0;font-size:12px;color:#5a7394;line-height:1.5;">
Or copy this link into your browser:
</p>
<p style="margin:4px 0 0;font-size:12px;word-break:break-all;line-height:1.5;">
<a href="%s" style="color:#6BB8FF;text-decoration:none;">%s</a>
</p>
</td></tr>

<!-- Footer divider -->
<tr><td style="padding:28px 40px 0;">
<div style="height:1px;background-color:#1a3355;"></div>
</td></tr>

<!-- Footer -->
<tr><td align="center" style="padding:16px 40px 28px;">
<p style="margin:0;font-size:12px;color:#4a6585;line-height:1.5;">
If you didn't create an AFK account, you can safely ignore this email.
</p>
</td></tr>

</table>
</td></tr>

<!-- Brand -->
<tr><td align="center" style="padding:28px 20px 0;">
<p style="margin:0;font-size:13px;color:#4a6585;letter-spacing:0.03em;">AFK</p>
<p style="margin:2px 0 0;font-size:11px;color:#3a5575;">Monitor Claude Code from your phone</p>
</td></tr>

</table>

</td></tr>
</table>
</body></html>`

type AuthHandler struct {
	DB              *sql.DB
	JWTSecret       string
	AppleBundleIDs  []string
	RequireTLS      bool   // reject password auth over plain HTTP
	ResendAPIKey    string // API key for resend.com email service
	BaseURL         string // public-facing URL for verification links
}

// requireTLS rejects requests that arrive over plain HTTP in production.
// Checks X-Forwarded-Proto (set by nginx/reverse proxy) or r.TLS.
func (h *AuthHandler) requireTLS(w http.ResponseWriter, r *http.Request) bool {
	if !h.RequireTLS {
		return true
	}
	if r.TLS != nil {
		return true
	}
	if r.Header.Get("X-Forwarded-Proto") == "https" && isTrustedProxy(r) {
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

	if ok, msg := validatePasswordComplexity(req.Password); !ok {
		writeError(w, msg, http.StatusBadRequest)
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

	// Generate verification token and send email.
	// sendVerificationEmail gracefully handles missing ResendAPIKey (logs warning, skips send).
	if err := h.sendVerificationEmail(user.ID, email); err != nil {
		slog.Error("failed to send verification email", "user_id", user.ID, "error", err)
	}

	writeJSON(w, http.StatusCreated, map[string]string{
		"status":  "verification_required",
		"message": "please check your email to verify your account",
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

	// Per-IP rate limiting: block IPs with excessive failed attempts across all accounts.
	ipKey := "ip:" + ip
	ipFailCount, _ := db.CountRecentFailedAttempts(h.DB, ipKey, rateLimitWindow)
	if ipFailCount >= maxFailedPerIP {
		writeError(w, "too many login attempts, try again later", http.StatusTooManyRequests)
		return
	}

	// Per-IP+email rate limiting: prevents brute-forcing a single account.
	lockoutKey := ip + ":" + email
	failCount, _ := db.CountRecentFailedAttempts(h.DB, lockoutKey, rateLimitWindow)
	if failCount >= maxFailedPerIPEmail {
		writeError(w, "too many login attempts, try again later", http.StatusTooManyRequests)
		return
	}

	user, err := db.GetUserByEmail(h.DB, email)
	if err != nil {
		// Run dummy bcrypt comparison to equalize timing with real user lookups.
		bcrypt.CompareHashAndPassword(dummyBcryptHash, []byte(req.Password))
		db.RecordLoginAttempt(h.DB, lockoutKey, false, ip)
		db.RecordLoginAttempt(h.DB, ipKey, false, ip)
		writeError(w, "invalid email or password", http.StatusUnauthorized)
		return
	}

	storedHash, err := db.GetPasswordHash(h.DB, user.ID)
	if err != nil {
		bcrypt.CompareHashAndPassword(dummyBcryptHash, []byte(req.Password))
		db.RecordLoginAttempt(h.DB, lockoutKey, false, ip)
		db.RecordLoginAttempt(h.DB, ipKey, false, ip)
		writeError(w, "invalid email or password", http.StatusUnauthorized)
		return
	}

	if err := bcrypt.CompareHashAndPassword([]byte(storedHash), []byte(req.Password)); err != nil {
		db.RecordLoginAttempt(h.DB, lockoutKey, false, ip)
		db.RecordLoginAttempt(h.DB, ipKey, false, ip)
		writeError(w, "invalid email or password", http.StatusUnauthorized)
		return
	}

	// Block login for unverified email users.
	if verified, err := db.IsEmailVerified(h.DB, user.ID); err == nil && !verified {
		db.RecordLoginAttempt(h.DB, lockoutKey, true, ip)
		db.RecordLoginAttempt(h.DB, ipKey, true, ip)
		writeJSON(w, http.StatusForbidden, map[string]string{
			"error":  "email_not_verified",
			"message": "Please verify your email before signing in.",
		})
		return
	}

	db.RecordLoginAttempt(h.DB, lockoutKey, true, ip)
	db.RecordLoginAttempt(h.DB, ipKey, true, ip)

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

// validatePasswordComplexity checks that the password contains at least one
// uppercase letter, one lowercase letter, one digit, and one special character.
func validatePasswordComplexity(password string) (bool, string) {
	var hasUpper, hasLower, hasDigit, hasSpecial bool
	for _, r := range password {
		switch {
		case r >= 'A' && r <= 'Z':
			hasUpper = true
		case r >= 'a' && r <= 'z':
			hasLower = true
		case r >= '0' && r <= '9':
			hasDigit = true
		default:
			hasSpecial = true
		}
	}
	if !hasUpper {
		return false, "password must contain at least one uppercase letter"
	}
	if !hasLower {
		return false, "password must contain at least one lowercase letter"
	}
	if !hasDigit {
		return false, "password must contain at least one digit"
	}
	if !hasSpecial {
		return false, "password must contain at least one special character"
	}
	return true, ""
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

// HandleVerifyEmail verifies a user's email address using a token.
// Supports both API calls (POST with JSON body) and browser visits (GET with ?token= query param).
// - API call (Accept: application/json or POST): returns JSON with auth tokens.
// - Browser visit (GET): returns an HTML page confirming verification.
func (h *AuthHandler) HandleVerifyEmail(w http.ResponseWriter, r *http.Request) {
	var token string

	if r.Method == http.MethodGet {
		// Browser visit via Universal Link or direct URL.
		token = r.URL.Query().Get("token")
	} else {
		// API call from iOS app.
		r.Body = http.MaxBytesReader(w, r.Body, maxAuthBodySize)
		var req struct {
			Token string `json:"token"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			writeError(w, "invalid request body", http.StatusBadRequest)
			return
		}
		token = req.Token
	}

	if token == "" {
		if r.Method == http.MethodGet {
			serveVerifyPage(w, false)
		} else {
			writeError(w, "token is required", http.StatusBadRequest)
		}
		return
	}

	userID, err := db.VerifyEmailToken(h.DB, token)
	if err != nil {
		if r.Method == http.MethodGet {
			serveVerifyPage(w, false)
		} else {
			writeError(w, "invalid or expired verification token", http.StatusBadRequest)
		}
		return
	}

	if err := db.SetEmailVerified(h.DB, userID); err != nil {
		slog.Error("failed to set email verified", "user_id", userID, "error", err)
		if r.Method == http.MethodGet {
			serveVerifyPage(w, false)
		} else {
			writeError(w, "verification failed", http.StatusInternalServerError)
		}
		return
	}

	slog.Info("email verified", "user_id", userID)

	// For browser visits, return a simple HTML success page.
	if r.Method == http.MethodGet {
		serveVerifyPage(w, true)
		return
	}

	// For API calls, issue tokens now that email is verified.
	tokenPair, err := auth.IssueTokenPair(userID, h.JWTSecret)
	if err != nil {
		writeError(w, "failed to issue tokens", http.StatusInternalServerError)
		return
	}

	tokenHash := hashToken(tokenPair.RefreshToken)
	expiresAt := time.Now().Add(30 * 24 * time.Hour)
	if err := db.StoreRefreshToken(h.DB, userID, tokenHash, "", expiresAt); err != nil {
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

// HandleResendVerification resends the verification email for an unverified user.
// Requires email + password to prevent abuse (proves they own the credentials).
func (h *AuthHandler) HandleResendVerification(w http.ResponseWriter, r *http.Request) {
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
	user, err := db.GetUserByEmail(h.DB, email)
	if err != nil {
		// Don't reveal whether email exists.
		bcrypt.CompareHashAndPassword(dummyBcryptHash, []byte(req.Password))
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
		return
	}

	storedHash, err := db.GetPasswordHash(h.DB, user.ID)
	if err != nil {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
		return
	}
	if err := bcrypt.CompareHashAndPassword([]byte(storedHash), []byte(req.Password)); err != nil {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
		return
	}

	// Only resend if not yet verified.
	if verified, err := db.IsEmailVerified(h.DB, user.ID); err == nil && verified {
		writeJSON(w, http.StatusOK, map[string]string{"status": "already_verified"})
		return
	}

	if err := h.sendVerificationEmail(user.ID, email); err != nil {
		slog.Error("failed to resend verification email", "user_id", user.ID, "error", err)
		writeError(w, "failed to send email, try again later", http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "message": "verification email sent"})
}

// serveVerifyPage serves the embedded static HTML page for email verification results.
func serveVerifyPage(w http.ResponseWriter, success bool) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	// Override the global CSP (default-src 'none') to allow inline styles/scripts and images.
	w.Header().Set("Content-Security-Policy",
		"default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self'")
	if success {
		w.Write(verifySuccessHTML)
	} else {
		w.WriteHeader(http.StatusBadRequest)
		w.Write(verifyFailHTML)
	}
}

// sendVerificationEmail generates a verification token and sends it via Resend.
// If ResendAPIKey is not configured, logs a warning and returns nil (graceful skip).
func (h *AuthHandler) sendVerificationEmail(userID, email string) error {
	// Generate random token.
	tokenBytes := make([]byte, 32)
	if _, err := rand.Read(tokenBytes); err != nil {
		return fmt.Errorf("generate token: %w", err)
	}
	token := hex.EncodeToString(tokenBytes)

	expiresAt := time.Now().Add(24 * time.Hour)
	if err := db.CreateEmailVerification(h.DB, userID, token, expiresAt); err != nil {
		return fmt.Errorf("store token: %w", err)
	}

	if h.ResendAPIKey == "" {
		slog.Warn("AFK_RESEND_API_KEY not configured, skipping verification email",
			"user_id", userID, "token", token)
		return nil
	}

	// Build verification URL as a Universal Link.
	base := h.BaseURL
	if base == "" {
		base = "https://afk.ahmetbirinci.dev"
	}
	verifyURL := base + "/verify?token=" + token

	// Send via Resend API.
	payload := map[string]interface{}{
		"from":    "AFK <noreply@afk.ahmetbirinci.dev>",
		"to":      []string{email},
		"subject": "Verify your AFK account",
		"html": fmt.Sprintf(verificationEmailHTML, base, verifyURL, verifyURL, verifyURL),
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshal email payload: %w", err)
	}

	req, err := http.NewRequest("POST", "https://api.resend.com/emails", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("create request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+h.ResendAPIKey)

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("send email: %w", err)
	}
	defer resp.Body.Close()
	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		return fmt.Errorf("resend API error (status %d): %s", resp.StatusCode, string(respBody))
	}

	slog.Info("verification email sent", "email", email[:1]+"***")
	return nil
}

func hashToken(token string) string {
	h := sha256.Sum256([]byte(token))
	return hex.EncodeToString(h[:])
}
