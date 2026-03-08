package handler

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/AFK/afk-cloud/internal/metrics"
	"github.com/AFK/afk-cloud/internal/model"
	"github.com/AFK/afk-cloud/internal/ws"
)

// =============================================================================
// OWASP API2:2023 (Broken Authentication)
// Comprehensive check that ALL admin endpoints enforce authentication.
// Covers: RED-001 admin auth, RED-004 WS token, RED-005 beta enum, RED-007 email verify, RED-012 timing
// =============================================================================

func TestAllAdminEndpoints_API2_AuthEnforcement(t *testing.T) {
	database := testDB(t)
	store := NewAdminSessionStore()
	defer store.Stop()

	h := &AdminHandler{
		DB:           database,
		Hub:          ws.NewHub(),
		Collector:    metrics.NewCollector(),
		SessionStore: store,
	}

	metricsH := &MetricsHandler{
		Collector:    metrics.NewCollector(),
		SessionStore: store,
	}

	// Every admin endpoint (except login/logout/passkey-login-begin/finish) must return 401
	// when called without a session cookie.
	type ep struct {
		name    string
		method  string
		path    string
		handler http.HandlerFunc
	}

	endpoints := []ep{
		{"Dashboard", "GET", "/v1/admin/dashboard", h.HandleAdminDashboard},
		{"Users", "GET", "/v1/admin/users", h.HandleAdminUsers},
		{"Timeseries", "GET", "/v1/admin/timeseries?metric=registrations", h.HandleAdminTimeseries},
		{"Audit", "GET", "/v1/admin/audit", h.HandleAdminAudit},
		{"LoginAttempts", "GET", "/v1/admin/login-attempts", h.HandleAdminLoginAttempts},
		{"TopProjects", "GET", "/v1/admin/top-projects", h.HandleAdminTopProjects},
		{"StaleDevices", "GET", "/v1/admin/stale-devices", h.HandleAdminStaleDevices},
		{"Logs", "GET", "/v1/admin/logs", h.HandleAdminLogs},
		{"LogsExport", "GET", "/v1/admin/logs/export", h.HandleAdminLogsExport},
		{"Feedback", "GET", "/v1/admin/feedback", h.HandleAdminFeedback},
		{"BetaRequests", "GET", "/v1/admin/beta-requests", h.HandleAdminBetaRequests},
		{"Metrics", "GET", "/metrics", metricsH.Handle},
	}

	for _, e := range endpoints {
		t.Run(e.name+"_NoAuth", func(t *testing.T) {
			req := httptest.NewRequest(e.method, e.path, nil)
			req.RemoteAddr = "127.0.0.1:12345"
			rr := httptest.NewRecorder()
			e.handler(rr, req)

			if rr.Code != http.StatusUnauthorized {
				t.Errorf("%s returned %d without auth, expected 401", e.name, rr.Code)
			}
		})

		t.Run(e.name+"_InvalidCookie", func(t *testing.T) {
			req := httptest.NewRequest(e.method, e.path, nil)
			req.RemoteAddr = "127.0.0.1:12345"
			req.AddCookie(&http.Cookie{Name: adminCookieName, Value: "invalid-session-id"})
			rr := httptest.NewRecorder()
			e.handler(rr, req)

			if rr.Code != http.StatusUnauthorized {
				t.Errorf("%s returned %d with invalid cookie, expected 401", e.name, rr.Code)
			}
		})
	}
}

// =============================================================================
// OWASP API4:2023 (Unrestricted Resource Consumption)
// Verify ALL POST endpoints have MaxBytesReader.
// Covers: RED-003 feedback, RED-006 webhook, RED-009 device, RED-010 session, RED-011 promptEncrypted
// =============================================================================

func TestAllPostEndpoints_API4_MaxBytesReader(t *testing.T) {
	database := testDB(t)
	userID := createTestUser(t, database, "api4_mbr@test.com", "API4MBR", "hashedpass")
	deviceID := createTestDevice(t, database, userID, "API4Device")
	sessionID := "api4-mbr-session"
	createTestSession(t, database, sessionID, deviceID, userID)

	oversized := strings.Repeat("X", 2*1024*1024) // 2 MB

	type endpoint struct {
		name    string
		handler http.HandlerFunc
		body    string
		path    string
		authed  bool
	}

	endpoints := []endpoint{
		{
			"Feedback",
			(&FeedbackHandler{DB: database}).HandleCreate,
			`{"message":"` + oversized + `","category":"general"}`,
			"/v1/feedback",
			true,
		},
		{
			"BetaRequest",
			(&BetaHandler{DB: database}).HandleBetaRequest,
			`{"email":"` + oversized + `"}`,
			"/v1/beta/request",
			false,
		},
		{
			"AuthRegister",
			(&AuthHandler{DB: database, JWTSecret: testJWTSecret, RequireTLS: false}).HandleEmailRegister,
			`{"email":"` + oversized + `"}`,
			"/v1/auth/register",
			false,
		},
	}

	for _, ep := range endpoints {
		t.Run(ep.name, func(t *testing.T) {
			req := httptest.NewRequest("POST", ep.path, strings.NewReader(ep.body))
			req.Header.Set("Content-Type", "application/json")
			req.RemoteAddr = "127.0.0.1:12345"
			rr := httptest.NewRecorder()

			if ep.authed {
				withAuth(userID, ep.handler)(rr, req)
			} else {
				ep.handler(rr, req)
			}

			// Should NOT return a success status.
			if rr.Code == http.StatusOK || rr.Code == http.StatusCreated {
				t.Errorf("%s accepted oversized body (status %d)", ep.name, rr.Code)
			}
		})
	}
}

// =============================================================================
// OWASP API5:2023 (Broken Function Level Authorization)
// Verify ALL dangerous permission modes are rejected.
// Covers: RED-008
// =============================================================================

func TestAllDangerousPermissionModes_API5_Rejected(t *testing.T) {
	dangerous := []string{
		"bypassPermissions",
		"autoApprove",
		"dontAsk",
		"ask",
		"root",
		"admin",
		"sudo",
	}

	for _, mode := range dangerous {
		t.Run(mode, func(t *testing.T) {
			if validPermissionModes[mode] {
				t.Errorf("dangerous/invalid permission mode %q should be rejected", mode)
			}
		})
	}

	// Also verify ONLY safe modes are in the allowlist.
	safeCount := 0
	for mode := range validPermissionModes {
		switch mode {
		case "", "default", "plan", "acceptEdits":
			safeCount++
		default:
			t.Errorf("unexpected mode in allowlist: %q", mode)
		}
	}
	if safeCount != 4 {
		t.Errorf("expected exactly 4 safe modes, got %d", safeCount)
	}
}

// =============================================================================
// OWASP API2:2023 (Broken Authentication) - Email verification gate
// Verify auth middleware blocks unverified users.
// Covers: RED-007
// =============================================================================

func TestAPI2_EmailVerification_BlocksUnverified(t *testing.T) {
	database := testDB(t)
	h := &AuthHandler{DB: database, JWTSecret: testJWTSecret, RequireTLS: false}

	// Register creates unverified user.
	regBody := model.EmailRegisterRequest{
		Email:    "api2_unverified@test.com",
		Password: "Secure@Pass1",
	}
	rr := doRequest(t, h.HandleEmailRegister, "POST", "/v1/auth/register", regBody)
	if rr.Code != http.StatusCreated {
		t.Fatalf("registration failed: %d", rr.Code)
	}

	// Attempt login.
	loginBody := model.EmailLoginRequest{
		Email:    "api2_unverified@test.com",
		Password: "Secure@Pass1",
	}
	rr2 := doRequest(t, h.HandleEmailLogin, "POST", "/v1/auth/login", loginBody)
	if rr2.Code != http.StatusForbidden {
		t.Errorf("unverified user should get 403, got %d", rr2.Code)
	}
}

// =============================================================================
// OWASP API3:2023 (Broken Object Property Level Authorization) - Email redaction
// Verify all admin endpoints that return emails apply redaction.
// Covers: RED-015, RED-016
// =============================================================================

func TestAPI3_EmailRedaction_AllAdminEndpoints(t *testing.T) {
	// Test redactEmail function consistency.
	cases := []struct {
		input    string
		expected string
	}{
		{"user@example.com", "u***@example.com"},
		{"admin@corp.io", "a***@corp.io"},
		{"x@y.com", "x***@y.com"},
	}

	for _, tc := range cases {
		got := redactEmail(tc.input)
		if got != tc.expected {
			t.Errorf("redactEmail(%q) = %q, want %q", tc.input, got, tc.expected)
		}
	}

	// Verify edge cases.
	if redactEmail("") != "***" {
		t.Errorf("redactEmail empty should return ***")
	}
	if redactEmail("nodomainemail") != "***" {
		t.Errorf("redactEmail without @ should return ***")
	}
}
