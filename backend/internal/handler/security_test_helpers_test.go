package handler

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/metrics"
)

// testDB creates an in-memory SQLite database with all migrations applied.
func testDB(t *testing.T) *sql.DB {
	t.Helper()
	database, err := db.Open(":memory:")
	if err != nil {
		t.Fatalf("open test db: %v", err)
	}
	if err := db.RunMigrations(database); err != nil {
		t.Fatalf("run migrations: %v", err)
	}
	t.Cleanup(func() { database.Close() })
	return database
}

// createTestUser creates a test email user and returns the user ID.
func createTestUser(t *testing.T, database *sql.DB, email, displayName, password string) string {
	t.Helper()
	user, err := db.CreateEmailUser(database, email, displayName, password)
	if err != nil {
		t.Fatalf("create test user: %v", err)
	}
	return user.ID
}

// createTestDevice creates a test device for the given user and returns the device ID.
func createTestDevice(t *testing.T, database *sql.DB, userID, name string) string {
	t.Helper()
	device, err := db.CreateDevice(database, userID, name, "test-pubkey", "test-system", "[]")
	if err != nil {
		t.Fatalf("create test device: %v", err)
	}
	return device.ID
}

// createTestSession creates a test session for the given device and user.
func createTestSession(t *testing.T, database *sql.DB, sessionID, deviceID, userID string) {
	t.Helper()
	_, err := database.Exec(`
		INSERT INTO sessions (id, device_id, user_id, status, started_at, updated_at, description)
		VALUES (?, ?, ?, 'running', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, '')
	`, sessionID, deviceID, userID)
	if err != nil {
		t.Fatalf("create test session: %v", err)
	}
}

// authedRequest creates an HTTP request with the user ID injected into context
// (simulating what AuthMiddleware does).
func authedRequest(method, path string, body interface{}, userID string) *http.Request {
	var bodyReader *bytes.Reader
	if body != nil {
		data, _ := json.Marshal(body)
		bodyReader = bytes.NewReader(data)
	} else {
		bodyReader = bytes.NewReader(nil)
	}
	req := httptest.NewRequest(method, path, bodyReader)
	req.Header.Set("Content-Type", "application/json")
	ctx := context.WithValue(req.Context(), contextKeyForTest, userID)
	return req.WithContext(ctx)
}

// contextKeyForTest is the same type as auth's contextKey for injecting userID.
// We use the auth package's exported function to read it, so we need to set it
// with the correct key. We'll build a middleware wrapper instead.
var contextKeyForTest interface{} // placeholder, see withAuth below

// withAuth wraps a handler to inject the userID into context the same way AuthMiddleware does.
func withAuth(userID string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		// Issue a real JWT token and validate it through AuthMiddleware
		// to get the context key set correctly.
		tp, _ := auth.IssueTokenPair(userID, testJWTSecret)
		r.Header.Set("Authorization", "Bearer "+tp.AccessToken)
		handler := auth.AuthMiddleware(testJWTSecret)(http.HandlerFunc(next))
		handler.ServeHTTP(w, r)
	}
}

const testJWTSecret = "test-secret-for-security-regression-tests"

// doAuthedRequest executes a handler with authentication and returns the response recorder.
func doAuthedRequest(t *testing.T, handler http.HandlerFunc, method, path string, body interface{}, userID string) *httptest.ResponseRecorder {
	t.Helper()
	return doAuthedRequestWithPathVals(t, handler, method, path, body, userID, nil)
}

// doAuthedRequestWithPathVals executes a handler with authentication and explicit path values.
func doAuthedRequestWithPathVals(t *testing.T, handler http.HandlerFunc, method, path string, body interface{}, userID string, pathVals map[string]string) *httptest.ResponseRecorder {
	t.Helper()
	var bodyBytes []byte
	if body != nil {
		bodyBytes, _ = json.Marshal(body)
	}
	req := httptest.NewRequest(method, path, bytes.NewReader(bodyBytes))
	req.Header.Set("Content-Type", "application/json")
	req.RemoteAddr = "127.0.0.1:12345"
	// Set HTTPS header so TLS check passes.
	req.Header.Set("X-Forwarded-Proto", "https")
	for k, v := range pathVals {
		req.SetPathValue(k, v)
	}
	rr := httptest.NewRecorder()
	withAuth(userID, handler)(rr, req)
	return rr
}

// doRequest executes a handler without authentication.
func doRequest(t *testing.T, handler http.HandlerFunc, method, path string, body interface{}) *httptest.ResponseRecorder {
	t.Helper()
	var bodyBytes []byte
	if body != nil {
		bodyBytes, _ = json.Marshal(body)
	}
	req := httptest.NewRequest(method, path, bytes.NewReader(bodyBytes))
	req.Header.Set("Content-Type", "application/json")
	req.RemoteAddr = "127.0.0.1:12345"
	rr := httptest.NewRecorder()
	handler(rr, req)
	return rr
}

// doAuthedRequestWithIP executes a handler with authentication and a specific remote IP.
func doAuthedRequestWithIP(t *testing.T, handler http.HandlerFunc, method, path string, body interface{}, userID, ip string) *httptest.ResponseRecorder {
	t.Helper()
	var bodyBytes []byte
	if body != nil {
		bodyBytes, _ = json.Marshal(body)
	}
	req := httptest.NewRequest(method, path, bytes.NewReader(bodyBytes))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-Forwarded-Proto", "https")
	req.RemoteAddr = ip + ":12345"
	rr := httptest.NewRecorder()
	withAuth(userID, handler)(rr, req)
	return rr
}

// parseResponseError extracts the "error" field from a JSON error response.
func parseResponseError(t *testing.T, rr *httptest.ResponseRecorder) string {
	t.Helper()
	var resp map[string]string
	if err := json.NewDecoder(rr.Body).Decode(&resp); err != nil {
		t.Fatalf("decode response body: %v (body: %s)", err, rr.Body.String())
	}
	return resp["error"]
}

// oversizedBody creates a string body larger than the given size in bytes.
func oversizedBody(size int) string {
	return strings.Repeat("A", size+1)
}

// newTestCollector creates a minimal metrics collector for tests.
func newTestCollector() *metrics.Collector {
	return metrics.NewCollector()
}
