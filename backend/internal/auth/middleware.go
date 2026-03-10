package auth

import (
	"context"
	"database/sql"
	"net/http"
	"strings"
)

type contextKey string

const userIDKey contextKey = "userID"

// EmailVerifiedChecker is a function that checks if a user's email is verified.
// Injected from the db package to avoid circular imports.
type EmailVerifiedChecker func(userID string) (bool, error)

func AuthMiddleware(secret string) func(http.Handler) http.Handler {
	return AuthMiddlewareWithVerification(secret, nil)
}

// AuthMiddlewareWithVerification creates auth middleware that also checks email verification.
// If verifyFn is nil, email verification is not checked (backward compat).
func AuthMiddlewareWithVerification(secret string, verifyFn EmailVerifiedChecker) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var tokenStr string

			// Check Authorization header first.
			if auth := r.Header.Get("Authorization"); auth != "" {
				if strings.HasPrefix(auth, "Bearer ") {
					tokenStr = strings.TrimPrefix(auth, "Bearer ")
				}
			}

			// Fall back to query parameter (for WebSocket).
			if tokenStr == "" {
				tokenStr = r.URL.Query().Get("token")
			}

			if tokenStr == "" {
				http.Error(w, `{"error":"missing authentication token"}`, http.StatusUnauthorized)
				return
			}

			userID, err := ValidateAccessToken(tokenStr, secret)
			if err != nil {
				http.Error(w, `{"error":"invalid or expired token"}`, http.StatusUnauthorized)
				return
			}

			// Block unverified users from all authenticated endpoints.
			if verifyFn != nil {
				if verified, err := verifyFn(userID); err == nil && !verified {
					http.Error(w, `{"error":"please verify your email before using the API"}`, http.StatusForbidden)
					return
				}
			}

			ctx := context.WithValue(r.Context(), userIDKey, userID)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// NewEmailVerifiedChecker creates an EmailVerifiedChecker backed by a database.
func NewEmailVerifiedChecker(database *sql.DB) EmailVerifiedChecker {
	return func(userID string) (bool, error) {
		var verified bool
		err := database.QueryRow(`SELECT email_verified FROM users WHERE id = $1`, userID).Scan(&verified)
		if err != nil {
			// If we can't check (e.g., column doesn't exist yet), allow through.
			return true, err
		}
		return verified, nil
	}
}

func UserIDFromContext(ctx context.Context) string {
	if v, ok := ctx.Value(userIDKey).(string); ok {
		return v
	}
	return ""
}
