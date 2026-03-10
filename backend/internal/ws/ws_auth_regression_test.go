package ws

import (
	"database/sql"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/db"
)

// =============================================================================
// RED-004 (CWE-598): Legacy ?token= query parameter removed
// =============================================================================

func TestAgentWS_CWE598_LegacyTokenRejected(t *testing.T) {
	database := wsTestDB(t)
	ticketStore := auth.NewTicketStore()
	hub := NewHub()

	handler := ServeAgentWS(hub, database, "test-secret", ticketStore)

	// Try to connect with ?token= (legacy auth).
	req := httptest.NewRequest("GET", "/ws/agent?token=some-jwt-token", nil)
	req.RemoteAddr = "127.0.0.1:12345"
	rr := httptest.NewRecorder()
	handler(rr, req)

	// Should be rejected (missing ws_ticket, not falling back to ?token=).
	if rr.Code == http.StatusSwitchingProtocols {
		t.Error("legacy ?token= should NOT be accepted for WS agent connection")
	}
	if rr.Code != http.StatusUnauthorized {
		t.Errorf("expected 401 for ?token= auth, got %d", rr.Code)
	}
}

func TestIOSWS_CWE598_LegacyTokenRejected(t *testing.T) {
	database := wsTestDB(t)
	ticketStore := auth.NewTicketStore()
	hub := NewHub()

	handler := ServeIOSWS(hub, database, "test-secret", ticketStore)

	// Try to connect with ?token= (legacy auth).
	req := httptest.NewRequest("GET", "/ws/ios?token=some-jwt-token", nil)
	req.RemoteAddr = "127.0.0.1:12345"
	rr := httptest.NewRecorder()
	handler(rr, req)

	if rr.Code == http.StatusSwitchingProtocols {
		t.Error("legacy ?token= should NOT be accepted for WS iOS connection")
	}
	if rr.Code != http.StatusUnauthorized {
		t.Errorf("expected 401 for ?token= auth, got %d", rr.Code)
	}
}

func TestAgentWS_CWE598_WSTicketStillWorks(t *testing.T) {
	database := wsTestDB(t)
	ticketStore := auth.NewTicketStore()

	// Create a user and device.
	userID := wsCreateTestUser(t, database, "ws_user@test.com", "WS User", "hashedpass")
	device, err := db.CreateDevice(database, userID, "WSDevice", "pub-key", "macOS", "[]")
	if err != nil {
		t.Fatalf("create device: %v", err)
	}

	// Issue a ws_ticket.
	ticket := ticketStore.Issue(userID, device.ID)

	hub := NewHub()
	handler := ServeAgentWS(hub, database, "test-secret", ticketStore)

	// Try with ws_ticket. Since we can't actually upgrade (no real WS connection),
	// the handler should at least get past auth (fail at upgrade, not at auth).
	req := httptest.NewRequest("GET", "/ws/agent?ws_ticket="+ticket, nil)
	req.RemoteAddr = "127.0.0.1:12345"
	rr := httptest.NewRecorder()
	handler(rr, req)

	// Should NOT return 401 (auth passed, fails at WS upgrade or later).
	if rr.Code == http.StatusUnauthorized {
		t.Error("valid ws_ticket should pass authentication")
	}
}

// wsTestDB creates a PostgreSQL test database for WS tests.
// Set AFK_TEST_DATABASE_URL to a PostgreSQL connection string (e.g. postgres://afk:afk@localhost:5432/afk_test?sslmode=disable).
func wsTestDB(t *testing.T) *sql.DB {
	t.Helper()
	dsn := os.Getenv("AFK_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("AFK_TEST_DATABASE_URL not set, skipping database test")
	}
	database, err := db.Open(dsn)
	if err != nil {
		t.Fatalf("open test db: %v", err)
	}
	if err := db.RunMigrations(database); err != nil {
		t.Fatalf("run migrations: %v", err)
	}
	t.Cleanup(func() { database.Close() })
	return database
}

// wsCreateTestUser creates a test user for WS auth tests.
func wsCreateTestUser(t *testing.T, database *sql.DB, email, name, pass string) string {
	t.Helper()
	user, err := db.CreateEmailUser(database, email, name, pass)
	if err != nil {
		t.Fatalf("create test user: %v", err)
	}
	return user.ID
}
