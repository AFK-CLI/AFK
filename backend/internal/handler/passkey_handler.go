package handler

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/go-webauthn/webauthn/protocol"
	"github.com/go-webauthn/webauthn/webauthn"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/model"
)

type PasskeyHandler struct {
	DB             *sql.DB
	JWTSecret      string
	WebAuthn       *webauthn.WebAuthn
	SessionStore   *auth.WebAuthnSessionStore
	TeamID         string
	AppleBundleIDs []string
}

// HandleRegisterBegin starts passkey registration for an authenticated user.
func (h *PasskeyHandler) HandleRegisterBegin(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	user, err := db.GetUser(h.DB, userID)
	if err != nil {
		writeError(w, "user not found", http.StatusNotFound)
		return
	}

	// Build existing credentials to exclude during registration.
	existingCreds, err := h.buildWebAuthnCredentials(userID)
	if err != nil {
		slog.Error("failed to load existing passkey credentials", "error", err)
		writeError(w, "internal error", http.StatusInternalServerError)
		return
	}

	waUser := &auth.WebAuthnUser{
		ID:          user.ID,
		Name:        user.Email,
		DisplayName: user.DisplayName,
		Credentials: existingCreds,
	}

	// Require discoverable (resident) key for passkey login support.
	options, session, err := h.WebAuthn.BeginRegistration(waUser,
		webauthn.WithResidentKeyRequirement(protocol.ResidentKeyRequirementRequired),
		webauthn.WithExclusions(webauthn.Credentials(existingCreds).CredentialDescriptors()),
	)
	if err != nil {
		slog.Error("failed to begin passkey registration", "error", err)
		writeError(w, "failed to begin registration", http.StatusInternalServerError)
		return
	}

	sessionKey := h.SessionStore.Save(session)

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"publicKey":  options.Response,
		"sessionKey": sessionKey,
	})
}

// HandleRegisterFinish completes passkey registration.
func (h *PasskeyHandler) HandleRegisterFinish(w http.ResponseWriter, r *http.Request) {
	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	// Buffer the body so we can extract sessionKey and still pass it to the webauthn library.
	bodyBytes, err := io.ReadAll(r.Body)
	if err != nil {
		writeError(w, "failed to read request body", http.StatusBadRequest)
		return
	}
	r.Body = io.NopCloser(bytes.NewReader(bodyBytes))

	var envelope struct {
		SessionKey string `json:"sessionKey"`
	}
	_ = json.Unmarshal(bodyBytes, &envelope)
	if envelope.SessionKey == "" {
		writeError(w, "missing sessionKey", http.StatusBadRequest)
		return
	}

	sessionData, ok := h.SessionStore.Get(envelope.SessionKey)
	if !ok {
		writeError(w, "session expired or invalid", http.StatusBadRequest)
		return
	}

	user, err := db.GetUser(h.DB, userID)
	if err != nil {
		writeError(w, "user not found", http.StatusNotFound)
		return
	}

	existingCreds, err := h.buildWebAuthnCredentials(userID)
	if err != nil {
		writeError(w, "internal error", http.StatusInternalServerError)
		return
	}

	waUser := &auth.WebAuthnUser{
		ID:          user.ID,
		Name:        user.Email,
		DisplayName: user.DisplayName,
		Credentials: existingCreds,
	}

	credential, err := h.WebAuthn.FinishRegistration(waUser, *sessionData, r)
	if err != nil {
		slog.Warn("passkey registration failed", "error", err, "user_id", userID)
		writeError(w, "registration verification failed", http.StatusBadRequest)
		return
	}

	// Marshal transports to JSON for storage.
	transportJSON, _ := json.Marshal(credential.Transport)

	credID := auth.GenerateID()
	if err := db.CreatePasskeyCredential(
		h.DB,
		credID,
		userID,
		credential.ID,
		credential.PublicKey,
		credential.AttestationType,
		string(transportJSON),
		credential.Authenticator.AAGUID,
		"Passkey",
		credential.Flags.BackupEligible,
		credential.Flags.BackupState,
	); err != nil {
		slog.Error("failed to store passkey credential", "error", err)
		writeError(w, "failed to store credential", http.StatusInternalServerError)
		return
	}

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// HandleLoginBegin starts passkey authentication (discoverable login, no user needed upfront).
func (h *PasskeyHandler) HandleLoginBegin(w http.ResponseWriter, r *http.Request) {
	options, session, err := h.WebAuthn.BeginDiscoverableLogin()
	if err != nil {
		slog.Error("failed to begin passkey login", "error", err)
		writeError(w, "failed to begin login", http.StatusInternalServerError)
		return
	}

	sessionKey := h.SessionStore.Save(session)

	writeJSON(w, http.StatusOK, map[string]interface{}{
		"publicKey":  options.Response,
		"sessionKey": sessionKey,
	})
}

// HandleLoginFinish completes passkey authentication and issues JWT tokens.
func (h *PasskeyHandler) HandleLoginFinish(w http.ResponseWriter, r *http.Request) {
	// Buffer the body so we can extract sessionKey and still pass it to the webauthn library.
	bodyBytes, err := io.ReadAll(r.Body)
	if err != nil {
		writeError(w, "failed to read request body", http.StatusBadRequest)
		return
	}
	r.Body = io.NopCloser(bytes.NewReader(bodyBytes))

	var envelope struct {
		SessionKey string `json:"sessionKey"`
	}
	_ = json.Unmarshal(bodyBytes, &envelope)
	if envelope.SessionKey == "" {
		writeError(w, "missing sessionKey", http.StatusBadRequest)
		return
	}

	sessionData, ok := h.SessionStore.Get(envelope.SessionKey)
	if !ok {
		writeError(w, "session expired or invalid", http.StatusBadRequest)
		return
	}

	// Discoverable login callback: look up user by credential's rawID or userHandle.
	userHandler := func(rawID, userHandle []byte) (webauthn.User, error) {
		// Try userHandle first (this is the WebAuthnID, which is the user ID).
		if len(userHandle) > 0 {
			user, err := db.GetUser(h.DB, string(userHandle))
			if err != nil {
				return nil, fmt.Errorf("user not found for handle: %w", err)
			}
			creds, err := h.buildWebAuthnCredentials(user.ID)
			if err != nil {
				return nil, err
			}
			return &auth.WebAuthnUser{
				ID:          user.ID,
				Name:        user.Email,
				DisplayName: user.DisplayName,
				Credentials: creds,
			}, nil
		}

		// Fall back to credential ID lookup.
		user, _, err := db.GetUserByPasskeyCredentialID(h.DB, rawID)
		if err != nil {
			return nil, fmt.Errorf("credential not found: %w", err)
		}
		creds, err := h.buildWebAuthnCredentials(user.ID)
		if err != nil {
			return nil, err
		}
		return &auth.WebAuthnUser{
			ID:          user.ID,
			Name:        user.Email,
			DisplayName: user.DisplayName,
			Credentials: creds,
		}, nil
	}

	credential, err := h.WebAuthn.FinishDiscoverableLogin(userHandler, *sessionData, r)
	if err != nil {
		slog.Warn("passkey login failed", "error", err)
		writeError(w, "authentication failed", http.StatusUnauthorized)
		return
	}

	// Look up the user via the credential to get user ID and passkey record ID.
	user, passkeyID, err := db.GetUserByPasskeyCredentialID(h.DB, credential.ID)
	if err != nil {
		writeError(w, "credential not found", http.StatusUnauthorized)
		return
	}

	// Update sign count in DB.
	_ = db.UpdatePasskeySignCount(h.DB, passkeyID, int(credential.Authenticator.SignCount))

	// Issue JWT tokens (same flow as email login).
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

// HandleAASA serves the Apple App Site Association file for passkey domain association.
func (h *PasskeyHandler) HandleAASA(w http.ResponseWriter, r *http.Request) {
	apps := make([]string, 0, len(h.AppleBundleIDs))
	for _, bundleID := range h.AppleBundleIDs {
		apps = append(apps, h.TeamID+"."+bundleID)
	}

	aasa := map[string]interface{}{
		"webcredentials": map[string]interface{}{
			"apps": apps,
		},
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(aasa)
}

// buildWebAuthnCredentials loads passkey credentials from DB and converts them to webauthn.Credential slice.
func (h *PasskeyHandler) buildWebAuthnCredentials(userID string) ([]webauthn.Credential, error) {
	dbCreds, err := db.GetPasskeyCredentials(h.DB, userID)
	if err != nil {
		return nil, fmt.Errorf("load passkey credentials: %w", err)
	}

	creds := make([]webauthn.Credential, 0, len(dbCreds))
	for _, dc := range dbCreds {
		var transports []protocol.AuthenticatorTransport
		_ = json.Unmarshal([]byte(dc.Transport), &transports)

		creds = append(creds, webauthn.Credential{
			ID:              dc.CredentialID,
			PublicKey:       dc.PublicKey,
			AttestationType: dc.AttestationType,
			Transport:       transports,
			Flags: webauthn.CredentialFlags{
				UserPresent:    true,
				UserVerified:   true,
				BackupEligible: dc.BackupEligible,
				BackupState:    dc.BackupState,
			},
			Authenticator: webauthn.Authenticator{
				AAGUID:       dc.AAGUID,
				SignCount:    uint32(dc.SignCount),
				CloneWarning: dc.CloneWarning != 0,
			},
		})
	}
	return creds, nil
}

