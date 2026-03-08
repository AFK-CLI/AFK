package middleware

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/metrics"
)

const testJWTSecret = "test-secret-for-ratelimit-tests"

// withAuth wraps a handler to inject the userID into context via real AuthMiddleware.
func withAuth(userID string, handler http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tp, _ := auth.IssueTokenPair(userID, testJWTSecret)
		r.Header.Set("Authorization", "Bearer "+tp.AccessToken)
		auth.AuthMiddleware(testJWTSecret)(handler).ServeHTTP(w, r)
	})
}

// =============================================================================
// Token bucket math
// =============================================================================

func TestTokenBucket_ConsumeTokens(t *testing.T) {
	rl := NewRateLimiter(5, 1, nil)
	defer rl.Stop()

	key := "user-1"
	for i := 0; i < 5; i++ {
		if !rl.Allow(key) {
			t.Errorf("Allow should return true for request %d", i+1)
		}
	}

	if rl.Allow(key) {
		t.Error("Allow should return false after all tokens consumed")
	}
}

func TestTokenBucket_RefillOverTime(t *testing.T) {
	// 2 tokens, 10 tokens/sec refill so 1 token refills in 100ms.
	rl := NewRateLimiter(2, 10, nil)
	defer rl.Stop()

	key := "user-refill"
	// Consume both tokens.
	rl.Allow(key)
	rl.Allow(key)

	if rl.Allow(key) {
		t.Error("should be exhausted immediately after consuming 2 tokens")
	}

	// Wait for refill (250ms margin to avoid flakiness under CI load).
	time.Sleep(250 * time.Millisecond)

	if !rl.Allow(key) {
		t.Error("Allow should return true after refill period")
	}
}

func TestTokenBucket_CappedAtMax(t *testing.T) {
	rl := NewRateLimiter(3, 100, nil) // fast refill
	defer rl.Stop()

	key := "user-cap"
	// Consume 1 token.
	rl.Allow(key)

	// Wait for excess refill.
	time.Sleep(100 * time.Millisecond)

	// Should still only allow 3 (the max), not more.
	allowed := 0
	for i := 0; i < 10; i++ {
		if rl.Allow(key) {
			allowed++
		}
	}
	if allowed > 3 {
		t.Errorf("allowed %d requests, but max tokens is 3", allowed)
	}
}

// =============================================================================
// Allow() returns false when exhausted, true after refill
// =============================================================================

func TestAllow_ExhaustedThenRefilled(t *testing.T) {
	rl := NewRateLimiter(1, 20, nil) // 1 token, 20/sec (refills in 50ms)
	defer rl.Stop()

	key := "exhaust-test"

	if !rl.Allow(key) {
		t.Fatal("first request should be allowed")
	}
	if rl.Allow(key) {
		t.Fatal("second request should be denied (0 tokens)")
	}

	// 200ms margin to avoid flakiness under CI load (needs 50ms to refill 1 token).
	time.Sleep(200 * time.Millisecond)

	if !rl.Allow(key) {
		t.Error("request should be allowed after refill")
	}
}

// =============================================================================
// Per-key isolation
// =============================================================================

func TestPerKeyIsolation(t *testing.T) {
	rl := NewRateLimiter(2, 0.001, nil) // nearly no refill
	defer rl.Stop()

	// Exhaust key-A.
	rl.Allow("key-A")
	rl.Allow("key-A")
	if rl.Allow("key-A") {
		t.Error("key-A should be exhausted")
	}

	// key-B should still be fresh.
	if !rl.Allow("key-B") {
		t.Error("key-B should have its own bucket and be allowed")
	}
	if !rl.Allow("key-B") {
		t.Error("key-B should still have tokens")
	}
}

// =============================================================================
// Stale bucket cleanup
// =============================================================================

func TestStaleBucketCleanup(t *testing.T) {
	rl := NewRateLimiter(5, 1, nil)
	defer rl.Stop()

	rl.Allow("stale-user")

	// Manually age the bucket's lastRefill to trigger cleanup.
	rl.mu.Lock()
	bucket := rl.buckets["stale-user"]
	bucket.lastRefill = time.Now().Add(-15 * time.Minute)
	rl.mu.Unlock()

	// Use the actual cleanup method.
	rl.cleanupStale()

	// Bucket should have been evicted.
	rl.mu.Lock()
	_, exists := rl.buckets["stale-user"]
	rl.mu.Unlock()

	if exists {
		t.Error("stale bucket should have been cleaned up")
	}
}

func TestStaleBucketCleanup_FreshBucketsSurvive(t *testing.T) {
	rl := NewRateLimiter(5, 1, nil)
	defer rl.Stop()

	rl.Allow("fresh-user")

	// Use the actual cleanup method.
	rl.cleanupStale()

	rl.mu.Lock()
	_, exists := rl.buckets["fresh-user"]
	rl.mu.Unlock()

	if !exists {
		t.Error("fresh bucket should NOT be cleaned up")
	}
}

// =============================================================================
// Metrics collector integration
// =============================================================================

func TestRateLimiter_MetricsCollectorCounts(t *testing.T) {
	collector := &metrics.Collector{}
	rl := NewRateLimiter(1, 0.001, collector)
	defer rl.Stop()

	rl.Allow("counted-user") // consumes token
	rl.Allow("counted-user") // should be denied, increments counter

	if collector.RateLimitHits.Load() != 1 {
		t.Errorf("RateLimitHits = %d, want 1", collector.RateLimitHits.Load())
	}
}

// =============================================================================
// Trusted proxy IP extraction
// =============================================================================

func TestClientIP_NoProxy(t *testing.T) {
	SetTrustedProxies(nil)
	defer SetTrustedProxies(nil)

	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "192.168.1.1:12345"

	ip := clientIP(req)
	if ip != "192.168.1.1" {
		t.Errorf("clientIP = %q, want %q", ip, "192.168.1.1")
	}
}

func TestClientIP_IgnoresXRealIP_WhenNoProxiesConfigured(t *testing.T) {
	SetTrustedProxies(nil)
	defer SetTrustedProxies(nil)

	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "10.0.0.1:8080"
	req.Header.Set("X-Real-IP", "203.0.113.5")

	ip := clientIP(req)
	// When no trusted proxies are configured, X-Real-IP should be ignored.
	if ip != "10.0.0.1" {
		t.Errorf("clientIP = %q, want %q (should ignore X-Real-IP without trusted proxies)", ip, "10.0.0.1")
	}
}

func TestClientIP_TrustsXRealIP_FromTrustedProxy(t *testing.T) {
	SetTrustedProxies([]string{"10.0.0.1"})
	defer SetTrustedProxies(nil)

	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "10.0.0.1:8080"
	req.Header.Set("X-Real-IP", "203.0.113.5")

	ip := clientIP(req)
	if ip != "203.0.113.5" {
		t.Errorf("clientIP = %q, want %q", ip, "203.0.113.5")
	}
}

func TestClientIP_IgnoresXRealIP_FromUntrustedSource(t *testing.T) {
	SetTrustedProxies([]string{"10.0.0.1"})
	defer SetTrustedProxies(nil)

	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "192.168.1.100:9999"
	req.Header.Set("X-Real-IP", "attacker-spoofed")

	ip := clientIP(req)
	if ip != "192.168.1.100" {
		t.Errorf("clientIP = %q, want %q (should ignore spoofed header)", ip, "192.168.1.100")
	}
}

func TestClientIP_RemoteAddrWithoutPort(t *testing.T) {
	SetTrustedProxies(nil)
	defer SetTrustedProxies(nil)

	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "192.168.1.1"

	ip := clientIP(req)
	if ip != "192.168.1.1" {
		t.Errorf("clientIP = %q, want %q", ip, "192.168.1.1")
	}
}

func TestSetTrustedProxies_EmptySlice(t *testing.T) {
	SetTrustedProxies([]string{})
	defer SetTrustedProxies(nil)

	if IsTrustedProxy("10.0.0.1") {
		t.Error("empty slice should not trust any IP")
	}
}

func TestSetTrustedProxies_SkipsEmptyStrings(t *testing.T) {
	SetTrustedProxies([]string{"10.0.0.1", "", "10.0.0.2"})
	defer SetTrustedProxies(nil)

	if !IsTrustedProxy("10.0.0.1") || !IsTrustedProxy("10.0.0.2") {
		t.Error("expected both non-empty IPs in trusted set")
	}
	if IsTrustedProxy("10.0.0.3") {
		t.Error("should not trust unlisted IP")
	}
}

func TestSetTrustedProxies_CIDR(t *testing.T) {
	SetTrustedProxies([]string{"172.16.0.0/12"})
	defer SetTrustedProxies(nil)

	if !IsTrustedProxy("172.22.0.1") {
		t.Error("172.22.0.1 should be trusted within 172.16.0.0/12")
	}
	if !IsTrustedProxy("172.31.255.254") {
		t.Error("172.31.255.254 should be trusted within 172.16.0.0/12")
	}
	if IsTrustedProxy("10.0.0.1") {
		t.Error("10.0.0.1 should not be trusted in 172.16.0.0/12")
	}
}

func TestSetTrustedProxies_MixedIPAndCIDR(t *testing.T) {
	SetTrustedProxies([]string{"10.0.0.1", "172.16.0.0/12"})
	defer SetTrustedProxies(nil)

	if !IsTrustedProxy("10.0.0.1") {
		t.Error("exact IP should be trusted")
	}
	if !IsTrustedProxy("172.22.0.5") {
		t.Error("IP in CIDR range should be trusted")
	}
	if IsTrustedProxy("192.168.1.1") {
		t.Error("IP outside both should not be trusted")
	}
}

// =============================================================================
// Middleware() HTTP handler
// =============================================================================

func TestMiddleware_AllowsAuthenticatedUser(t *testing.T) {
	rl := NewRateLimiter(10, 1, nil)
	defer rl.Stop()

	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	handler := withAuth("user-mw", rl.Middleware(inner))

	req := httptest.NewRequest("GET", "/api/test", nil)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", rr.Code)
	}
}

func TestMiddleware_Returns429WhenExhausted(t *testing.T) {
	rl := NewRateLimiter(1, 0.001, nil) // 1 token, nearly no refill
	defer rl.Stop()

	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	handler := withAuth("user-limited", rl.Middleware(inner))

	// First should pass.
	req := httptest.NewRequest("GET", "/api/test", nil)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)
	if rr.Code != http.StatusOK {
		t.Errorf("first request: status = %d, want 200", rr.Code)
	}

	// Second should be rate-limited.
	req2 := httptest.NewRequest("GET", "/api/test", nil)
	rr2 := httptest.NewRecorder()
	handler.ServeHTTP(rr2, req2)
	if rr2.Code != http.StatusTooManyRequests {
		t.Errorf("second request: status = %d, want 429", rr2.Code)
	}
	if rr2.Header().Get("Retry-After") != "5" {
		t.Errorf("Retry-After = %q, want %q", rr2.Header().Get("Retry-After"), "5")
	}
}

func TestMiddleware_SkipsUnauthenticatedRequests(t *testing.T) {
	rl := NewRateLimiter(1, 0.001, nil)
	defer rl.Stop()

	called := false
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		called = true
		w.WriteHeader(http.StatusOK)
	})
	// Do NOT wrap with withAuth, so no userID in context.
	handler := rl.Middleware(inner)

	req := httptest.NewRequest("GET", "/api/test", nil)
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	if !called {
		t.Error("inner handler should be called for unauthenticated requests")
	}
	if rr.Code != http.StatusOK {
		t.Errorf("status = %d, want 200 (rate limiter should skip unauthenticated)", rr.Code)
	}
}

// =============================================================================
// IPMiddleware() HTTP handler
// =============================================================================

func TestIPMiddleware_AllowsRequests(t *testing.T) {
	SetTrustedProxies(nil)
	rl := NewRateLimiter(10, 1, nil)
	defer rl.Stop()

	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	handler := rl.IPMiddleware(inner)

	req := httptest.NewRequest("GET", "/api/test", nil)
	req.RemoteAddr = "10.0.0.1:1234"
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("status = %d, want 200", rr.Code)
	}
}

func TestIPMiddleware_Returns429WhenExhausted(t *testing.T) {
	SetTrustedProxies(nil)
	rl := NewRateLimiter(1, 0.001, nil)
	defer rl.Stop()

	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	handler := rl.IPMiddleware(inner)

	makeReq := func() *httptest.ResponseRecorder {
		req := httptest.NewRequest("GET", "/api/test", nil)
		req.RemoteAddr = "10.0.0.50:1234"
		rr := httptest.NewRecorder()
		handler.ServeHTTP(rr, req)
		return rr
	}

	// First should pass.
	if rr := makeReq(); rr.Code != http.StatusOK {
		t.Errorf("first request: status = %d, want 200", rr.Code)
	}

	// Second should be rate-limited.
	rr := makeReq()
	if rr.Code != http.StatusTooManyRequests {
		t.Errorf("second request: status = %d, want 429", rr.Code)
	}
	if rr.Header().Get("Retry-After") != "10" {
		t.Errorf("Retry-After = %q, want %q", rr.Header().Get("Retry-After"), "10")
	}
}

func TestIPMiddleware_DifferentIPsGetSeparateBuckets(t *testing.T) {
	SetTrustedProxies(nil)
	rl := NewRateLimiter(1, 0.001, nil)
	defer rl.Stop()

	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	handler := rl.IPMiddleware(inner)

	// Exhaust one IP.
	req1 := httptest.NewRequest("GET", "/", nil)
	req1.RemoteAddr = "1.1.1.1:1234"
	rr1 := httptest.NewRecorder()
	handler.ServeHTTP(rr1, req1)
	if rr1.Code != http.StatusOK {
		t.Fatalf("first IP first request should pass")
	}

	// Different IP should still be allowed.
	req2 := httptest.NewRequest("GET", "/", nil)
	req2.RemoteAddr = "2.2.2.2:1234"
	rr2 := httptest.NewRecorder()
	handler.ServeHTTP(rr2, req2)
	if rr2.Code != http.StatusOK {
		t.Errorf("different IP should have its own bucket, got status %d", rr2.Code)
	}
}

// =============================================================================
// Stop() terminates cleanup goroutine
// =============================================================================

func TestRateLimiter_Stop(t *testing.T) {
	rl := NewRateLimiter(5, 1, nil)
	// Should not panic on single or double stop.
	rl.Stop()
	rl.Stop() // must not panic thanks to sync.Once
}

// =============================================================================
// New bucket starts at maxTokens
// =============================================================================

func TestNewBucket_StartsAtMaxTokens(t *testing.T) {
	rl := NewRateLimiter(7, 0.001, nil)
	defer rl.Stop()

	allowed := 0
	for i := 0; i < 20; i++ {
		if rl.Allow("new-user") {
			allowed++
		}
	}
	if allowed != 7 {
		t.Errorf("new bucket should start with 7 tokens, got %d", allowed)
	}
}
