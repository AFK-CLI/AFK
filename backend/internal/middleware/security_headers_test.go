package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

// =============================================================================
// RED-012 (CWE-693): Security headers present on all responses
// =============================================================================

func TestSecurityHeaders_CWE693_AllHeadersPresent(t *testing.T) {
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	handler := SecurityHeaders(inner)

	req := httptest.NewRequest("GET", "/any-path", nil)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	expected := map[string]string{
		"Strict-Transport-Security": "max-age=31536000; includeSubDomains",
		"X-Frame-Options":           "DENY",
		"X-Content-Type-Options":    "nosniff",
		"Referrer-Policy":           "strict-origin-when-cross-origin",
		"Content-Security-Policy":   "default-src 'none'; frame-ancestors 'none'",
	}

	for header, expectedValue := range expected {
		got := rr.Header().Get(header)
		if got == "" {
			t.Errorf("missing security header: %s", header)
		} else if got != expectedValue {
			t.Errorf("header %s: got %q, want %q", header, got, expectedValue)
		}
	}
}

func TestSecurityHeaders_CWE693_PresentOnErrorResponses(t *testing.T) {
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "not found", http.StatusNotFound)
	})
	handler := SecurityHeaders(inner)

	req := httptest.NewRequest("GET", "/nonexistent", nil)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	// All headers should still be present even on error responses.
	headers := []string{
		"Strict-Transport-Security",
		"X-Frame-Options",
		"X-Content-Type-Options",
		"Referrer-Policy",
		"Content-Security-Policy",
	}
	for _, h := range headers {
		if rr.Header().Get(h) == "" {
			t.Errorf("security header %s missing from error response", h)
		}
	}
}

func TestSecurityHeaders_CWE693_PresentOnPOSTResponses(t *testing.T) {
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusCreated)
	})
	handler := SecurityHeaders(inner)

	req := httptest.NewRequest("POST", "/v1/tasks", nil)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	if rr.Header().Get("Strict-Transport-Security") == "" {
		t.Error("HSTS header missing from POST response")
	}
	if rr.Header().Get("X-Frame-Options") != "DENY" {
		t.Error("X-Frame-Options should be DENY")
	}
}

// =============================================================================
// RED-004 (CWE-799): Rate limiter config validation
// =============================================================================

func TestRateLimiter_CWE799_StricterRegistrationLimiter(t *testing.T) {
	// The registration rate limiter should have fewer tokens and slower refill
	// than the general auth rate limiter.
	generalLimiter := NewRateLimiter(10, 1.0/6.0, nil)
	defer generalLimiter.Stop()
	registerLimiter := NewRateLimiter(3, 1.0/1200.0, nil)
	defer registerLimiter.Stop()

	// The register limiter should exhaust faster.
	key := "test-ip"
	for i := 0; i < 3; i++ {
		if !registerLimiter.Allow(key) {
			t.Errorf("register limiter should allow request %d", i+1)
		}
	}
	// 4th request should be rejected.
	if registerLimiter.Allow(key) {
		t.Error("register limiter should reject 4th request")
	}

	// General limiter should still have tokens.
	for i := 0; i < 10; i++ {
		if !generalLimiter.Allow(key) {
			t.Errorf("general limiter should allow request %d", i+1)
		}
	}
}

// =============================================================================
// RED-008 (CWE-770): Subscription sync rate limiting verification
// =============================================================================

func TestRateLimiter_CWE770_PerUserMiddleware(t *testing.T) {
	limiter := NewRateLimiter(2, 0.001, nil) // 2 tokens, nearly no refill
	defer limiter.Stop()

	// Simulate 3 requests from the same user.
	allowed := 0
	for i := 0; i < 3; i++ {
		if limiter.Allow("user1") {
			allowed++
		}
	}
	if allowed != 2 {
		t.Errorf("expected 2 allowed requests before rate limit, got %d", allowed)
	}
}

// =============================================================================
// RED-017 (CWE-770): Dedicated continue rate limiter
// =============================================================================

func TestRateLimiter_CWE770_ContinueLimiterTighter(t *testing.T) {
	// Continue limiter: 5 tokens, 1/sec refill.
	continueLimiter := NewRateLimiter(5, 1, nil)
	defer continueLimiter.Stop()
	// General limiter: 10 tokens, 2/sec refill.
	generalLimiter := NewRateLimiter(10, 2, nil)
	defer generalLimiter.Stop()

	key := "user-continue-test"

	// Continue limiter should exhaust at 5.
	for i := 0; i < 5; i++ {
		if !continueLimiter.Allow(key) {
			t.Errorf("continue limiter should allow request %d", i+1)
		}
	}
	if continueLimiter.Allow(key) {
		t.Error("continue limiter should reject 6th request")
	}

	// General limiter should allow up to 10.
	for i := 0; i < 10; i++ {
		if !generalLimiter.Allow(key) {
			t.Errorf("general limiter should allow request %d", i+1)
		}
	}
	if generalLimiter.Allow(key) {
		t.Error("general limiter should reject 11th request")
	}
}

// =============================================================================
// RED-019 (CWE-770): Task creation rate limiting verification
// =============================================================================

func TestRateLimiter_CWE770_TaskCreationLimited(t *testing.T) {
	// Task creation uses the general limiter (10 tokens, 2/sec).
	taskLimiter := NewRateLimiter(10, 2, nil)
	defer taskLimiter.Stop()

	key := "task-create-user"
	for i := 0; i < 10; i++ {
		if !taskLimiter.Allow(key) {
			t.Errorf("task limiter should allow request %d", i+1)
		}
	}
	if taskLimiter.Allow(key) {
		t.Error("task limiter should reject 11th request")
	}
}
