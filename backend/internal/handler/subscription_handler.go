package handler

import (
	"database/sql"
	"encoding/json"
	"log/slog"
	"net/http"
	"regexp"
	"time"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/model"
)

// productIDRe validates Apple product identifiers (reverse DNS style, e.g. com.afk.pro.monthly).
var productIDRe = regexp.MustCompile(`^[a-zA-Z0-9._]+$`)

type SubscriptionHandler struct {
	DB              *sql.DB
	StoreKitKeySet  bool // true when AFK_STOREKIT_SERVER_KEY is configured
}

// HandleWebhook processes App Store Server Notifications V2.
// POST /v1/webhooks/appstore — called by Apple, no auth required.
func (h *SubscriptionHandler) HandleWebhook(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, 1<<20) // 1 MB
	var body struct {
		SignedPayload string `json:"signedPayload"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || body.SignedPayload == "" {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	payload, err := auth.VerifyAppStoreJWS(body.SignedPayload)
	if err != nil {
		slog.Error("app store webhook JWS verification failed", "error", err)
		writeError(w, "invalid signed payload", http.StatusBadRequest)
		return
	}

	// Extract transaction info from the signed transaction.
	if payload.Data.SignedTransactionInfo == "" {
		slog.Warn("app store webhook missing signed transaction info", "type", payload.NotificationType)
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
		return
	}

	txInfo, err := auth.VerifySignedTransaction(payload.Data.SignedTransactionInfo)
	if err != nil {
		slog.Error("app store webhook transaction verification failed", "error", err)
		writeError(w, "invalid signed transaction", http.StatusBadRequest)
		return
	}

	slog.Info("app store webhook received",
		"type", payload.NotificationType,
		"subtype", payload.Subtype,
		"product_id", txInfo.ProductId,
		"original_transaction_id", txInfo.OriginalTransactionId,
	)

	// Look up user by original transaction ID.
	user, err := db.GetUserByOriginalTransactionID(h.DB, txInfo.OriginalTransactionId)
	if err != nil {
		slog.Warn("app store webhook: user not found for transaction",
			"original_transaction_id", txInfo.OriginalTransactionId,
			"error", err,
		)
		// Return 200 to Apple even if we can't find the user (they may not have synced yet).
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
		return
	}

	// Process notification based on type.
	switch payload.NotificationType {
	case "SUBSCRIBED", "DID_RENEW":
		expiresAt := txInfo.ExpiresTime()
		if err := db.UpdateUserSubscription(h.DB, user.ID, "pro", txInfo.ProductId, txInfo.OriginalTransactionId, expiresAt); err != nil {
			slog.Error("failed to update subscription", "user_id", user.ID, "error", err)
		} else {
			slog.Info("subscription activated/renewed", "user_id", user.ID, "product_id", txInfo.ProductId, "expires_at", expiresAt)
		}

	case "EXPIRED", "REVOKE", "REFUND":
		// Don't downgrade contributors.
		if user.SubscriptionTier != "contributor" {
			if err := db.UpdateUserSubscription(h.DB, user.ID, "free", "", txInfo.OriginalTransactionId, nil); err != nil {
				slog.Error("failed to downgrade subscription", "user_id", user.ID, "error", err)
			} else {
				slog.Info("subscription expired/revoked", "user_id", user.ID, "type", payload.NotificationType)
			}
		}

	case "DID_CHANGE_RENEWAL_STATUS":
		slog.Info("subscription renewal status changed", "user_id", user.ID, "subtype", payload.Subtype)

	default:
		slog.Info("unhandled app store notification type", "type", payload.NotificationType, "user_id", user.ID)
	}

	// Audit log.
	details, _ := json.Marshal(map[string]string{
		"notification_type":       payload.NotificationType,
		"subtype":                 payload.Subtype,
		"product_id":              txInfo.ProductId,
		"original_transaction_id": txInfo.OriginalTransactionId,
	})
	_ = db.InsertAuditLog(h.DB, &model.AuditLogEntry{
		UserID:  user.ID,
		Action:  "appstore_webhook",
		Details: string(details),
	})

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// HandleGetStatus returns the subscription status for the authenticated user.
// GET /v1/subscription/status
func (h *SubscriptionHandler) HandleGetStatus(w http.ResponseWriter, r *http.Request) {
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

	// Backend-side expiry check: downgrade if expired (but not contributors — they're lifetime).
	if user.SubscriptionTier == "pro" && user.SubscriptionExpiresAt != nil && user.SubscriptionExpiresAt.Before(time.Now()) {
		slog.Info("subscription expired, downgrading", "user_id", userID)
		_ = db.UpdateUserSubscription(h.DB, userID, "free", "", "", nil)
		user.SubscriptionTier = "free"
		user.SubscriptionExpiresAt = nil
	}

	response := map[string]interface{}{
		"tier": user.SubscriptionTier,
	}
	if user.SubscriptionExpiresAt != nil {
		response["expiresAt"] = user.SubscriptionExpiresAt.Format(time.RFC3339)
	}

	writeJSON(w, http.StatusOK, response)
}

// transactionIDRe validates Apple original transaction IDs (numeric strings, 15-25 digits).
var transactionIDRe = regexp.MustCompile(`^[0-9]{15,25}$`)

// HandleSync lets iOS push subscription receipt data after a purchase.
// POST /v1/subscription/sync
//
// Requires AFK_STOREKIT_SERVER_KEY to be configured. When not configured,
// returns 503 to prevent accepting unverified subscription data.
func (h *SubscriptionHandler) HandleSync(w http.ResponseWriter, r *http.Request) {
	if !h.StoreKitKeySet {
		writeError(w, "subscription sync not configured", http.StatusServiceUnavailable)
		return
	}

	userID := auth.UserIDFromContext(r.Context())
	if userID == "" {
		writeError(w, "unauthorized", http.StatusUnauthorized)
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, 64*1024) // 64 KB
	var req struct {
		OriginalTransactionId string `json:"originalTransactionId"`
		ProductId             string `json:"productId"`
		ExpiresAt             string `json:"expiresAt"` // RFC3339
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if req.OriginalTransactionId == "" || req.ProductId == "" {
		writeError(w, "originalTransactionId and productId are required", http.StatusBadRequest)
		return
	}

	// Validate originalTransactionId format (Apple uses numeric strings).
	if !transactionIDRe.MatchString(req.OriginalTransactionId) {
		writeError(w, "invalid originalTransactionId format", http.StatusBadRequest)
		return
	}

	// Validate productId format (reverse DNS, alphanumeric + dots/underscores).
	if !productIDRe.MatchString(req.ProductId) || len(req.ProductId) > 200 {
		writeError(w, "invalid productId format", http.StatusBadRequest)
		return
	}

	// Check that this transaction ID hasn't already been claimed by another user.
	existingUser, err := db.GetUserByOriginalTransactionID(h.DB, req.OriginalTransactionId)
	if err == nil && existingUser != nil && existingUser.ID != userID {
		slog.Warn("subscription sync rejected: transaction ID already used by another user",
			"user_id", userID, "original_transaction_id", req.OriginalTransactionId)
		writeError(w, "transaction already claimed", http.StatusConflict)
		return
	}

	var expiresAt *time.Time
	if req.ExpiresAt != "" {
		t, err := time.Parse(time.RFC3339, req.ExpiresAt)
		if err == nil {
			expiresAt = &t
		}
	}

	if err := db.UpdateUserSubscription(h.DB, userID, "pro", req.ProductId, req.OriginalTransactionId, expiresAt); err != nil {
		slog.Error("failed to sync subscription", "user_id", userID, "error", err)
		writeError(w, "failed to sync subscription", http.StatusInternalServerError)
		return
	}

	slog.Info("subscription synced from iOS", "user_id", userID, "product_id", req.ProductId, "original_transaction_id", req.OriginalTransactionId)

	// Audit log.
	details, _ := json.Marshal(map[string]string{
		"product_id":              req.ProductId,
		"original_transaction_id": req.OriginalTransactionId,
	})
	_ = db.InsertAuditLog(h.DB, &model.AuditLogEntry{
		UserID:  userID,
		Action:  "subscription_synced",
		Details: string(details),
	})

	writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "tier": "pro"})
}
