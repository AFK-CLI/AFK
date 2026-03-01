package middleware

import (
	"net"
	"net/http"
	"sync"
	"time"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/metrics"
)

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

// Stop terminates the cleanup goroutine.
func (rl *RateLimiter) Stop() {
	close(rl.stop)
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

// clientIP extracts the client IP from the request, preferring X-Real-IP
// (set by nginx) and falling back to RemoteAddr.
func clientIP(r *http.Request) string {
	if ip := r.Header.Get("X-Real-IP"); ip != "" {
		return ip
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func (rl *RateLimiter) cleanup() {
	ticker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			rl.mu.Lock()
			cutoff := time.Now().Add(-10 * time.Minute)
			for id, bucket := range rl.buckets {
				if bucket.lastRefill.Before(cutoff) {
					delete(rl.buckets, id)
				}
			}
			rl.mu.Unlock()
		case <-rl.stop:
			return
		}
	}
}
