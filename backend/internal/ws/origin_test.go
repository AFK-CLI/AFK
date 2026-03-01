package ws

import (
	"net/http/httptest"
	"testing"
)

// =============================================================================
// RED-006 (CWE-346): WebSocket origin check
// =============================================================================

func TestWSOrigin_CWE346_EmptyOriginAccepted(t *testing.T) {
	// Reset origins for test.
	origOrigins := allowedWSOrigins
	defer func() { allowedWSOrigins = origOrigins }()
	allowedWSOrigins = []string{"https://afk.example.com"}

	req := httptest.NewRequest("GET", "/v1/ws/agent", nil)
	// No Origin header set (simulating native apps).
	if !upgrader.CheckOrigin(req) {
		t.Error("empty origin should be accepted (native apps)")
	}
}

func TestWSOrigin_CWE346_NonAllowedOriginRejected(t *testing.T) {
	origOrigins := allowedWSOrigins
	defer func() { allowedWSOrigins = origOrigins }()
	allowedWSOrigins = []string{"https://afk.example.com"}

	cases := []string{
		"https://evil.com",
		"https://attacker.example.com",
		"http://afk.example.com", // wrong scheme
		"https://afk.example.com.evil.com",
	}
	for _, origin := range cases {
		t.Run(origin, func(t *testing.T) {
			req := httptest.NewRequest("GET", "/v1/ws/agent", nil)
			req.Header.Set("Origin", origin)
			if upgrader.CheckOrigin(req) {
				t.Errorf("origin %q should be rejected", origin)
			}
		})
	}
}

func TestWSOrigin_CWE346_AllowedOriginAccepted(t *testing.T) {
	origOrigins := allowedWSOrigins
	defer func() { allowedWSOrigins = origOrigins }()
	allowedWSOrigins = []string{"https://afk.example.com", "https://dev.afk.example.com"}

	cases := []string{
		"https://afk.example.com",
		"https://dev.afk.example.com",
	}
	for _, origin := range cases {
		t.Run(origin, func(t *testing.T) {
			req := httptest.NewRequest("GET", "/v1/ws/agent", nil)
			req.Header.Set("Origin", origin)
			if !upgrader.CheckOrigin(req) {
				t.Errorf("origin %q should be accepted", origin)
			}
		})
	}
}

func TestWSOrigin_CWE346_InitWSOriginsParsesCSV(t *testing.T) {
	origOrigins := allowedWSOrigins
	defer func() { allowedWSOrigins = origOrigins }()
	allowedWSOrigins = nil

	InitWSOrigins("https://a.com, https://b.com , https://c.com")
	if len(allowedWSOrigins) != 3 {
		t.Errorf("expected 3 origins, got %d: %v", len(allowedWSOrigins), allowedWSOrigins)
	}
}

func TestWSOrigin_CWE346_NoOriginsConfigured(t *testing.T) {
	origOrigins := allowedWSOrigins
	defer func() { allowedWSOrigins = origOrigins }()
	allowedWSOrigins = nil

	// With no origins configured, only empty origin should be allowed.
	req := httptest.NewRequest("GET", "/v1/ws/agent", nil)
	req.Header.Set("Origin", "https://anything.com")
	if upgrader.CheckOrigin(req) {
		t.Error("non-empty origin should be rejected when no origins are configured")
	}

	// Empty origin still allowed.
	req2 := httptest.NewRequest("GET", "/v1/ws/agent", nil)
	if !upgrader.CheckOrigin(req2) {
		t.Error("empty origin should still be accepted")
	}
}
