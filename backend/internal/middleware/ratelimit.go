package middleware

import (
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/metrics"
)

var (
	trustedProxyMu   sync.RWMutex
	trustedProxyIPs  map[string]bool
	trustedProxyCIDR []*net.IPNet
)

// SetTrustedProxies configures the set of IPs allowed to set X-Real-IP.
// Supports both exact IPs ("10.0.0.1") and CIDR ranges ("172.16.0.0/12").
// Call once at startup. An empty slice means no trusted proxies.
func SetTrustedProxies(proxies []string) {
	trustedProxyMu.Lock()
	defer trustedProxyMu.Unlock()
	if len(proxies) == 0 {
		trustedProxyIPs = nil
		trustedProxyCIDR = nil
		return
	}
	ips := make(map[string]bool)
	var cidrs []*net.IPNet
	for _, p := range proxies {
		if p == "" {
			continue
		}
		if _, ipNet, err := net.ParseCIDR(p); err == nil {
			cidrs = append(cidrs, ipNet)
		} else {
			ips[p] = true
		}
	}
	if len(ips) == 0 {
		trustedProxyIPs = nil
	} else {
		trustedProxyIPs = ips
	}
	trustedProxyCIDR = cidrs
}

// TokenBucket implements a token bucket rate limiter.
type TokenBucket struct {
	tokens     float64
	maxTokens  float64
	refillRate float64 // tokens per second
	lastRefill time.Time
}

// RateLimiter is a per-user token bucket rate limiter.
type RateLimiter struct {
	mu         sync.Mutex
	buckets    map[string]*TokenBucket
	maxTokens  float64
	refillRate float64
	collector  *metrics.Collector
	stop       chan struct{}
	stopOnce   sync.Once
}

// NewRateLimiter creates a rate limiter with given max tokens and refill rate.
func NewRateLimiter(maxTokens, refillRate float64, collector *metrics.Collector) *RateLimiter {
	rl := &RateLimiter{
		buckets:    make(map[string]*TokenBucket),
		maxTokens:  maxTokens,
		refillRate: refillRate,
		collector:  collector,
		stop:       make(chan struct{}),
	}
	go rl.cleanup()
	return rl
}

// Stop terminates the cleanup goroutine. Safe to call multiple times.
func (rl *RateLimiter) Stop() {
	rl.stopOnce.Do(func() { close(rl.stop) })
}

// allow checks if a request from the given key should be allowed.
func (rl *RateLimiter) allow(key string) bool {
	rl.mu.Lock()
	defer rl.mu.Unlock()

	bucket, ok := rl.buckets[key]
	if !ok {
		bucket = &TokenBucket{
			tokens:     rl.maxTokens,
			maxTokens:  rl.maxTokens,
			refillRate: rl.refillRate,
			lastRefill: time.Now(),
		}
		rl.buckets[key] = bucket
	}

	now := time.Now()
	elapsed := now.Sub(bucket.lastRefill).Seconds()
	bucket.tokens += elapsed * bucket.refillRate
	if bucket.tokens > bucket.maxTokens {
		bucket.tokens = bucket.maxTokens
	}
	bucket.lastRefill = now

	if bucket.tokens < 1 {
		if rl.collector != nil {
			rl.collector.RateLimitHits.Add(1)
		}
		return false
	}

	bucket.tokens--
	return true
}

// Allow checks if a request from the given user should be allowed.
func (rl *RateLimiter) Allow(userID string) bool {
	return rl.allow(userID)
}

// Middleware returns an HTTP middleware that rate-limits based on user ID.
func (rl *RateLimiter) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		userID := auth.UserIDFromContext(r.Context())
		if userID == "" {
			next.ServeHTTP(w, r)
			return
		}

		if !rl.Allow(userID) {
			w.Header().Set("Retry-After", "5")
			http.Error(w, `{"error":"rate limit exceeded"}`, http.StatusTooManyRequests)
			return
		}

		next.ServeHTTP(w, r)
	})
}

// IPMiddleware returns an HTTP middleware that rate-limits based on client IP.
func (rl *RateLimiter) IPMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ip := clientIP(r)
		if !rl.allow(ip) {
			w.Header().Set("Retry-After", "10")
			http.Error(w, `{"error":"too many requests"}`, http.StatusTooManyRequests)
			return
		}

		next.ServeHTTP(w, r)
	})
}

// clientIP extracts the client IP from the request.
// Only trusts X-Real-IP if no trusted proxies are configured (backward compat)
// or if the direct connection comes from a trusted proxy IP.
func clientIP(r *http.Request) string {
	directIP, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		directIP = r.RemoteAddr
	}

	if forwarded := r.Header.Get("X-Real-IP"); forwarded != "" {
		if isTrusted(directIP) {
			return forwarded
		}
	}

	return directIP
}

// isTrusted checks if an IP matches the configured trusted proxies (exact or CIDR).
func isTrusted(ip string) bool {
	trustedProxyMu.RLock()
	ips := trustedProxyIPs
	cidrs := trustedProxyCIDR
	trustedProxyMu.RUnlock()

	if ips == nil && len(cidrs) == 0 {
		return false
	}
	if ips != nil && ips[ip] {
		return true
	}
	if len(cidrs) > 0 {
		parsed := net.ParseIP(ip)
		if parsed != nil {
			for _, cidr := range cidrs {
				if cidr.Contains(parsed) {
					return true
				}
			}
		}
	}
	return false
}

// IsTrustedProxy checks if the given IP is in the configured trusted proxy set.
func IsTrustedProxy(ip string) bool {
	return isTrusted(ip)
}

// cleanupStale removes buckets that haven't been accessed in over 10 minutes.
func (rl *RateLimiter) cleanupStale() {
	rl.mu.Lock()
	defer rl.mu.Unlock()
	cutoff := time.Now().Add(-10 * time.Minute)
	for id, bucket := range rl.buckets {
		if bucket.lastRefill.Before(cutoff) {
			delete(rl.buckets, id)
		}
	}
}

func (rl *RateLimiter) cleanup() {
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			rl.cleanupStale()
		case <-rl.stop:
			return
		}
	}
}
