package metrics

import (
	"fmt"
	"strings"
	"sync/atomic"
	"time"
)

// Collector tracks application metrics using atomic counters.
type Collector struct {
	startTime time.Time

	// HTTP request counters
	RequestsTotal   atomic.Int64
	RequestErrors   atomic.Int64
	RequestsByRoute map[string]*atomic.Int64

	// WebSocket counters
	WSAgentConnections  atomic.Int64
	WSIOSConnections    atomic.Int64
	WSMessagesReceived  atomic.Int64
	WSMessagesSent      atomic.Int64
	WSDroppedMessages   atomic.Int64

	// Command counters
	CommandsSubmitted atomic.Int64
	CommandsCompleted atomic.Int64
	CommandsFailed    atomic.Int64
	CommandsCancelled atomic.Int64

	// Rate limit counters
	RateLimitHits atomic.Int64
}

func NewCollector() *Collector {
	return &Collector{
		startTime:       time.Now(),
		RequestsByRoute: make(map[string]*atomic.Int64),
	}
}

func (c *Collector) Uptime() time.Duration {
	return time.Since(c.startTime)
}

func (c *Collector) IncrementRoute(route string) {
	if counter, ok := c.RequestsByRoute[route]; ok {
		counter.Add(1)
	}
}

// RegisterRoute pre-registers a route for per-route counting.
func (c *Collector) RegisterRoute(route string) {
	c.RequestsByRoute[route] = &atomic.Int64{}
}

// Prometheus returns metrics in Prometheus exposition format.
func (c *Collector) Prometheus() string {
	var b strings.Builder

	writeGauge(&b, "afk_uptime_seconds", float64(c.Uptime().Seconds()))
	writeCounter(&b, "afk_http_requests_total", float64(c.RequestsTotal.Load()))
	writeCounter(&b, "afk_http_request_errors_total", float64(c.RequestErrors.Load()))

	writeGauge(&b, "afk_ws_agent_connections", float64(c.WSAgentConnections.Load()))
	writeGauge(&b, "afk_ws_ios_connections", float64(c.WSIOSConnections.Load()))
	writeCounter(&b, "afk_ws_messages_received_total", float64(c.WSMessagesReceived.Load()))
	writeCounter(&b, "afk_ws_messages_sent_total", float64(c.WSMessagesSent.Load()))
	writeCounter(&b, "afk_ws_dropped_messages_total", float64(c.WSDroppedMessages.Load()))

	writeCounter(&b, "afk_commands_submitted_total", float64(c.CommandsSubmitted.Load()))
	writeCounter(&b, "afk_commands_completed_total", float64(c.CommandsCompleted.Load()))
	writeCounter(&b, "afk_commands_failed_total", float64(c.CommandsFailed.Load()))
	writeCounter(&b, "afk_commands_cancelled_total", float64(c.CommandsCancelled.Load()))

	writeCounter(&b, "afk_rate_limit_hits_total", float64(c.RateLimitHits.Load()))

	for route, counter := range c.RequestsByRoute {
		label := fmt.Sprintf(`afk_http_requests_by_route{route="%s"}`, route)
		writeCounter(&b, label, float64(counter.Load()))
	}

	return b.String()
}

func writeCounter(b *strings.Builder, name string, value float64) {
	fmt.Fprintf(b, "%s %g\n", name, value)
}

func writeGauge(b *strings.Builder, name string, value float64) {
	fmt.Fprintf(b, "%s %g\n", name, value)
}
