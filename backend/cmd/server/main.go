package main

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/config"
	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/handler"
	"github.com/AFK/afk-cloud/internal/metrics"
	"github.com/AFK/afk-cloud/internal/middleware"
	"github.com/AFK/afk-cloud/internal/monitor"
	"github.com/AFK/afk-cloud/internal/push"
	"github.com/AFK/afk-cloud/internal/ws"
)

// Version is set at build time via ldflags.
var Version = "dev"

func main() {
	cfg := config.Load()
	cfg.SetupLogging()

	if err := cfg.Validate(); err != nil {
		fmt.Fprintf(os.Stderr, "Configuration error: %v\n", err)
		os.Exit(1)
	}

	slog.Info("AFK Cloud starting", "port", cfg.Port, "log_level", cfg.LogLevel, "version", Version)
	slog.Info("database configured", "path", cfg.DatabasePath)

	database, err := db.Open(cfg.DatabasePath)
	if err != nil {
		slog.Error("failed to open database", "error", err)
		os.Exit(1)
	}
	defer database.Close()

	if err := db.RunMigrations(database); err != nil {
		slog.Error("failed to run migrations", "error", err)
		os.Exit(1)
	}
	slog.Info("migrations applied successfully")

	hub := ws.NewHub()

	// Initialize allowed WebSocket origins.
	ws.InitWSOrigins(os.Getenv("AFK_WS_ALLOWED_ORIGINS"))

	// Initialize APNs push client.
	apnsClient, err := push.NewAPNsClient(cfg.APNsKeyPath, cfg.APNsKeyID, cfg.APNsTeamID, cfg.APNsBundleID, cfg.APNsProduction)
	if err != nil {
		slog.Error("failed to initialize APNs client", "error", err)
		os.Exit(1)
	}

	// Create push notifier and decision engine, attach to hub.
	notifier := push.NewNotifier(apnsClient, database, hub.HasActiveIOSConns)
	hub.Notifier = notifier
	hub.Decision = push.NewDecisionEngine(notifier, hub.HasActiveIOSConns)

	// Configure trusted proxies for X-Real-IP header trust.
	middleware.SetTrustedProxies(cfg.TrustedProxies)
	if len(cfg.TrustedProxies) > 0 {
		slog.Info("trusted proxies configured", "count", len(cfg.TrustedProxies))
	}

	// Load or generate server Ed25519 key pair for command signing.
	var serverPrivateKey ed25519.PrivateKey
	if cfg.ServerPrivateKey != "" {
		privBytes, err := hex.DecodeString(cfg.ServerPrivateKey)
		if err != nil {
			slog.Error("failed to decode server private key", "error", err)
			os.Exit(1)
		}
		serverPrivateKey = ed25519.PrivateKey(privBytes)
		// Log fingerprint (SHA-256 first 8 bytes) instead of full key.
		fp := sha256.Sum256(serverPrivateKey.Public().(ed25519.PublicKey))
		slog.Info("server Ed25519 key pair loaded from config", "fingerprint", hex.EncodeToString(fp[:8]))
	} else {
		pub, priv, err := auth.GenerateServerKeyPair()
		if err != nil {
			slog.Error("failed to generate server key pair", "error", err)
			os.Exit(1)
		}
		serverPrivateKey = priv
		fp := sha256.Sum256(pub)
		slog.Info("generated ephemeral server Ed25519 key pair", "fingerprint", hex.EncodeToString(fp[:8]))
		slog.Warn("set AFK_SERVER_PRIVATE_KEY for persistent key across restarts")
	}

	// Nonce store for replay protection on commands (10 minute TTL).
	nonceStore := auth.NewNonceStore(10 * time.Minute)
	nonceStop := make(chan struct{})
	go func() {
		ticker := time.NewTicker(1 * time.Minute)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				nonceStore.Cleanup()
			case <-nonceStop:
				return
			}
		}
	}()

	// Ticket store for short-lived WS auth tickets.
	ticketStore := auth.NewTicketStore()
	stop := make(chan os.Signal, 1)
	ticketStop := make(chan struct{})
	ticketStore.StartCleanup(ticketStop)

	// Metrics collector.
	collector := metrics.NewCollector()

	// Rate limiter for general command submission (10 tokens, 2/sec refill).
	rateLimiter := middleware.NewRateLimiter(10, 2, collector)

	// Tighter rate limiter for session continue (5 tokens, 1/sec refill).
	continueRateLimiter := middleware.NewRateLimiter(5, 1, collector)

	// IP rate limiter for auth endpoints (10 tokens, 10/min = 1/6 sec refill).
	authIPLimiter := middleware.NewRateLimiter(10, 1.0/6.0, collector)

	// Stricter IP rate limiter for registration (3 tokens, 3/hour = 1/1200 sec refill).
	registerIPLimiter := middleware.NewRateLimiter(3, 1.0/1200.0, collector)

	// Admin login limiter (3 tokens, 1/20s = 3/min) — brute-force protection.
	adminLoginLimiter := middleware.NewRateLimiter(3, 1.0/20.0, collector)

	// Admin read limiter (20 tokens, 2/sec) — prevents scraping.
	adminReadLimiter := middleware.NewRateLimiter(20, 2, collector)

	authMiddleware := auth.AuthMiddleware(cfg.JWTSecret)

	authHandler := &handler.AuthHandler{
		DB:            database,
		JWTSecret:     cfg.JWTSecret,
		AppleBundleIDs: cfg.AppleBundleIDs,
		RequireTLS:    true,
	}
	deviceHandler := &handler.DeviceHandler{DB: database, Hub: hub}
	sessionHandler := &handler.SessionHandler{DB: database}
	healthHandler := &handler.HealthHandler{Hub: hub, DB: database, Collector: collector, Version: Version}
	metricsHandler := &handler.MetricsHandler{Collector: collector, AdminSecret: cfg.AdminSecret}

	mux := http.NewServeMux()

	// Health (public liveness) and detailed health (authed).
	mux.HandleFunc("GET /healthz", healthHandler.HandleLiveness)
	mux.Handle("GET /healthz/detail", authMiddleware(http.HandlerFunc(healthHandler.Handle)))
	mux.Handle("GET /metrics", authIPLimiter.IPMiddleware(http.HandlerFunc(metricsHandler.Handle)))

	// Auth (IP rate limiting on all auth endpoints).
	mux.Handle("POST /v1/auth/apple", authIPLimiter.IPMiddleware(http.HandlerFunc(authHandler.HandleAppleAuth)))
	mux.Handle("POST /v1/auth/refresh", authIPLimiter.IPMiddleware(http.HandlerFunc(authHandler.HandleRefresh)))
	mux.Handle("POST /v1/auth/register", registerIPLimiter.IPMiddleware(http.HandlerFunc(authHandler.HandleEmailRegister)))
	mux.Handle("POST /v1/auth/login", authIPLimiter.IPMiddleware(http.HandlerFunc(authHandler.HandleEmailLogin)))
	mux.Handle("DELETE /v1/auth/logout", authMiddleware(http.HandlerFunc(authHandler.HandleLogout)))

	// WS ticket (with auth).
	mux.Handle("POST /v1/auth/ws-ticket", authMiddleware(http.HandlerFunc(handler.HandleCreateTicket(ticketStore))))

	// Devices (with auth).
	mux.Handle("POST /v1/devices", authMiddleware(http.HandlerFunc(deviceHandler.HandleCreate)))
	mux.Handle("GET /v1/devices", authMiddleware(http.HandlerFunc(deviceHandler.HandleList)))
	mux.Handle("DELETE /v1/devices/{id}", authMiddleware(http.HandlerFunc(deviceHandler.HandleDelete)))

	// Privacy mode (with auth).
	mux.Handle("PUT /v1/devices/{id}/privacy", authMiddleware(http.HandlerFunc(deviceHandler.HandleSetPrivacyMode)))
	mux.Handle("PUT /v1/devices/{id}/projects/privacy", authMiddleware(http.HandlerFunc(deviceHandler.HandleSetProjectPrivacy)))

	// Key exchange (with auth).
	keyExchangeHandler := &handler.KeyExchangeHandler{DB: database, Hub: hub}
	mux.Handle("POST /v1/devices/{id}/key-agreement", authMiddleware(http.HandlerFunc(keyExchangeHandler.HandleRegisterKey)))
	mux.Handle("GET /v1/devices/{id}/key-agreement", authMiddleware(http.HandlerFunc(keyExchangeHandler.HandleGetPeerKey)))
	mux.Handle("GET /v1/devices/{id}/key-agreement/{version}", authMiddleware(http.HandlerFunc(keyExchangeHandler.HandleGetPeerKeyByVersion)))

	// Audit (with auth).
	auditHandler := &handler.AuditHandler{DB: database}
	mux.Handle("GET /v1/audit", authMiddleware(http.HandlerFunc(auditHandler.HandleList)))

	// Projects (with auth).
	projectHandler := &handler.ProjectHandler{DB: database}
	mux.Handle("GET /v1/projects", authMiddleware(http.HandlerFunc(projectHandler.HandleList)))

	// Tasks (with auth).
	taskHandler := &handler.TaskHandler{DB: database}
	mux.Handle("GET /v1/tasks", authMiddleware(http.HandlerFunc(taskHandler.HandleList)))
	mux.Handle("POST /v1/tasks", authMiddleware(rateLimiter.Middleware(http.HandlerFunc(taskHandler.HandleCreate))))
	mux.Handle("PUT /v1/tasks/{id}", authMiddleware(http.HandlerFunc(taskHandler.HandleUpdate)))
	mux.Handle("DELETE /v1/tasks/{id}", authMiddleware(http.HandlerFunc(taskHandler.HandleDelete)))

	// Todos (with auth).
	todoHandler := &handler.TodoHandler{DB: database, Hub: hub, NonceStore: nonceStore, ServerPrivateKey: serverPrivateKey}
	mux.Handle("GET /v1/todos", authMiddleware(http.HandlerFunc(todoHandler.HandleList)))
	mux.Handle("POST /v1/todos/append", authMiddleware(http.HandlerFunc(todoHandler.HandleAppend)))
	mux.Handle("POST /v1/todos/toggle", authMiddleware(http.HandlerFunc(todoHandler.HandleToggle)))
	mux.Handle("POST /v1/todos/start-session", authMiddleware(rateLimiter.Middleware(http.HandlerFunc(todoHandler.HandleStartSession))))

	// App logs (with auth).
	logHandler := &handler.LogHandler{DB: database}
	mux.Handle("GET /v1/logs", authMiddleware(http.HandlerFunc(logHandler.HandleList)))
	mux.Handle("POST /v1/logs", authMiddleware(rateLimiter.Middleware(http.HandlerFunc(logHandler.HandleBatch))))

	// Feedback (with auth).
	feedbackHandler := &handler.FeedbackHandler{DB: database}
	mux.Handle("GET /v1/feedback", authMiddleware(http.HandlerFunc(feedbackHandler.HandleList)))
	mux.Handle("POST /v1/feedback", authMiddleware(rateLimiter.Middleware(http.HandlerFunc(feedbackHandler.HandleCreate))))

	// Push tokens (with auth).
	pushHandler := &handler.PushHandler{DB: database}
	mux.Handle("POST /v1/push-tokens", authMiddleware(http.HandlerFunc(pushHandler.HandleRegister)))
	mux.Handle("DELETE /v1/push-tokens", authMiddleware(http.HandlerFunc(pushHandler.HandleDelete)))

	// Push-to-start token (with auth).
	pushToStartHandler := &handler.PushToStartHandler{DB: database}
	mux.Handle("POST /v1/push-to-start-token", authMiddleware(http.HandlerFunc(pushToStartHandler.HandleRegister)))

	// Notification preferences (with auth).
	notifPrefsHandler := &handler.NotificationPrefsHandler{DB: database}
	mux.Handle("GET /v1/notification-preferences", authMiddleware(http.HandlerFunc(notifPrefsHandler.HandleGet)))
	mux.Handle("PUT /v1/notification-preferences", authMiddleware(http.HandlerFunc(notifPrefsHandler.HandleUpdate)))

	// Sessions (with auth).
	mux.Handle("GET /v1/sessions", authMiddleware(http.HandlerFunc(sessionHandler.HandleList)))
	mux.Handle("GET /v1/sessions/{id}", authMiddleware(http.HandlerFunc(sessionHandler.HandleDetail)))

	// Command continue, cancel, and new chat (with auth + rate limiting).
	mux.Handle("POST /v2/sessions/{id}/continue", authMiddleware(continueRateLimiter.Middleware(http.HandlerFunc(handler.HandleContinue(hub, database, nonceStore, serverPrivateKey)))))
	mux.Handle("POST /v2/sessions/{id}/cancel", authMiddleware(http.HandlerFunc(handler.HandleCancelCommand(hub, database))))
	mux.Handle("POST /v1/commands/new", authMiddleware(rateLimiter.Middleware(http.HandlerFunc(handler.HandleNewChat(hub, database, nonceStore, serverPrivateKey)))))

	// Live Activity token registration (with auth).
	mux.Handle("POST /v2/sessions/{id}/live-activity-token", authMiddleware(http.HandlerFunc(handler.HandleRegisterLiveActivityToken(hub, database))))

	// Subscriptions.
	subscriptionHandler := &handler.SubscriptionHandler{
		DB:             database,
		StoreKitKeySet: os.Getenv("AFK_STOREKIT_SERVER_KEY") != "",
	}
	mux.HandleFunc("POST /v1/webhooks/appstore", subscriptionHandler.HandleWebhook)
	mux.Handle("GET /v1/subscription/status", authMiddleware(http.HandlerFunc(subscriptionHandler.HandleGetStatus)))
	mux.Handle("POST /v1/subscription/sync", authMiddleware(rateLimiter.Middleware(http.HandlerFunc(subscriptionHandler.HandleSync))))

	// Admin (secret-based auth with rate limiting, not JWT).
	var adminSessionStore *handler.AdminSessionStore
	if cfg.AdminSecret != "" {
		adminSessionStore = handler.NewAdminSessionStore(cfg.AdminSecret)
	}
	adminHandler := &handler.AdminHandler{
		DB:           database,
		AdminSecret:  cfg.AdminSecret,
		Hub:          hub,
		Collector:    collector,
		Version:      Version,
		SessionStore: adminSessionStore,
	}
	mux.Handle("POST /v1/admin/grant-contributor", adminLoginLimiter.IPMiddleware(http.HandlerFunc(adminHandler.HandleGrantContributor)))
	mux.HandleFunc("GET /admin", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/admin/", http.StatusMovedPermanently)
	})
	mux.Handle("/admin/", handler.AdminFileServer())
	mux.Handle("POST /v1/admin/login", adminLoginLimiter.IPMiddleware(http.HandlerFunc(adminHandler.HandleAdminLogin)))
	mux.Handle("POST /v1/admin/logout", adminReadLimiter.IPMiddleware(http.HandlerFunc(adminHandler.HandleAdminLogout)))
	// Admin read endpoints — rate limited to prevent scraping.
	mux.Handle("GET /v1/admin/dashboard", adminReadLimiter.IPMiddleware(http.HandlerFunc(adminHandler.HandleAdminDashboard)))
	mux.Handle("GET /v1/admin/users", adminReadLimiter.IPMiddleware(http.HandlerFunc(adminHandler.HandleAdminUsers)))
	mux.Handle("GET /v1/admin/timeseries", adminReadLimiter.IPMiddleware(http.HandlerFunc(adminHandler.HandleAdminTimeseries)))
	mux.Handle("GET /v1/admin/audit", adminReadLimiter.IPMiddleware(http.HandlerFunc(adminHandler.HandleAdminAudit)))
	mux.Handle("GET /v1/admin/login-attempts", adminReadLimiter.IPMiddleware(http.HandlerFunc(adminHandler.HandleAdminLoginAttempts)))
	mux.Handle("GET /v1/admin/top-projects", adminReadLimiter.IPMiddleware(http.HandlerFunc(adminHandler.HandleAdminTopProjects)))
	mux.Handle("GET /v1/admin/stale-devices", adminReadLimiter.IPMiddleware(http.HandlerFunc(adminHandler.HandleAdminStaleDevices)))
	mux.Handle("GET /v1/admin/users/{id}", adminReadLimiter.IPMiddleware(http.HandlerFunc(adminHandler.HandleAdminUserDetail)))
	mux.Handle("GET /v1/admin/devices", adminReadLimiter.IPMiddleware(http.HandlerFunc(adminHandler.HandleAdminDevicesList)))
	mux.Handle("GET /v1/admin/sessions", adminReadLimiter.IPMiddleware(http.HandlerFunc(adminHandler.HandleAdminSessionsList)))
	mux.Handle("GET /v1/admin/sessions/{id}", adminReadLimiter.IPMiddleware(http.HandlerFunc(adminHandler.HandleAdminSessionDetail)))
	mux.Handle("GET /v1/admin/commands", adminReadLimiter.IPMiddleware(http.HandlerFunc(adminHandler.HandleAdminCommandsList)))
	mux.Handle("GET /v1/admin/logs", adminReadLimiter.IPMiddleware(http.HandlerFunc(adminHandler.HandleAdminLogs)))
	mux.Handle("GET /v1/admin/logs/export", adminReadLimiter.IPMiddleware(http.HandlerFunc(adminHandler.HandleAdminLogsExport)))
	mux.Handle("GET /v1/admin/feedback", adminReadLimiter.IPMiddleware(http.HandlerFunc(adminHandler.HandleAdminFeedback)))

	// Admin write endpoints — rate limited to prevent accidental spam.
	mux.Handle("PUT /v1/admin/users/{id}/tier", authIPLimiter.IPMiddleware(http.HandlerFunc(adminHandler.HandleAdminUpdateUserTier)))
	mux.Handle("DELETE /v1/admin/users/{id}", authIPLimiter.IPMiddleware(http.HandlerFunc(adminHandler.HandleAdminRevokeUser)))
	mux.Handle("DELETE /v1/admin/devices/{id}", authIPLimiter.IPMiddleware(http.HandlerFunc(adminHandler.HandleAdminRevokeDevice)))
	mux.Handle("POST /v1/admin/devices/{id}/rotate-keys", authIPLimiter.IPMiddleware(http.HandlerFunc(adminHandler.HandleAdminForceKeyRotation)))
	mux.Handle("PUT /v1/admin/sessions/{id}/status", authIPLimiter.IPMiddleware(http.HandlerFunc(adminHandler.HandleAdminUpdateSessionStatus)))

	// Landing page.
	landingHandler := handler.LandingFileServer()
	mux.Handle("GET /{$}", landingHandler)
	mux.Handle("GET /icon.png", landingHandler)

	// Static pages (privacy policy, terms of service).
	mux.HandleFunc("GET /privacy", handler.HandlePrivacy)
	mux.HandleFunc("GET /terms", handler.HandleTerms)

	// WebSocket endpoints (auth via ws-ticket or legacy token query param).
	mux.HandleFunc("GET /v1/ws/agent", ws.ServeAgentWS(hub, database, cfg.JWTSecret, ticketStore))
	mux.HandleFunc("GET /v1/ws/app", ws.ServeIOSWS(hub, database, cfg.JWTSecret, ticketStore))

	// Stuck session detector (check every 2 minutes, threshold 5 minutes).
	stuckDetector := monitor.NewStuckDetector(database, hub, 5*time.Minute, 2*time.Minute)
	stuckDetector.Start()

	// Event purger (every 24h, free: 7-day TTL, pro: 90-day TTL).
	eventPurger := monitor.NewEventPurger(database, 24*time.Hour, 7*24*time.Hour, 90*24*time.Hour)
	eventPurger.Start()

	// Periodic cleanup of old login attempts (hourly, entries older than 24h).
	loginCleanupStop := make(chan struct{})
	go func() {
		ticker := time.NewTicker(1 * time.Hour)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				db.CleanupOldLoginAttempts(database, 24*time.Hour)
			case <-loginCleanupStop:
				return
			}
		}
	}()

	// Data retention cleanup (daily, 30s startup delay).
	// SA-019: Purge audit logs older than 90 days.
	// SA-020: Purge expired/revoked refresh tokens with 7-day grace.
	// SA-021: Purge expired commands older than 7 days.
	retentionStop := make(chan struct{})
	go func() {
		time.Sleep(30 * time.Second)
		runRetentionCleanup(database)
		ticker := time.NewTicker(24 * time.Hour)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				runRetentionCleanup(database)
			case <-retentionStop:
				return
			}
		}
	}()

	// Wrap with security headers, request ID, and request logging middleware.
	wrappedMux := middleware.Logger(middleware.RequestID(middleware.SecurityHeaders(mux)))

	srv := &http.Server{
		Addr:         ":" + cfg.Port,
		Handler:      wrappedMux,
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	// Graceful shutdown.
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		slog.Info("server listening", "addr", ":"+cfg.Port)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("server error", "error", err)
			os.Exit(1)
		}
	}()

	<-stop
	slog.Info("shutting down server...")

	close(ticketStop)
	close(nonceStop)
	close(loginCleanupStop)
	close(retentionStop)
	rateLimiter.Stop()
	continueRateLimiter.Stop()
	authIPLimiter.Stop()
	registerIPLimiter.Stop()
	adminLoginLimiter.Stop()
	adminReadLimiter.Stop()
	if adminSessionStore != nil {
		adminSessionStore.Stop()
	}
	stuckDetector.Stop()
	eventPurger.Stop()
	hub.Shutdown()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := srv.Shutdown(ctx); err != nil {
		slog.Error("server forced to shutdown", "error", err)
		os.Exit(1)
	}

	slog.Info("server stopped")
}

// runRetentionCleanup performs periodic data retention housekeeping.
func runRetentionCleanup(database *sql.DB) {
	// Audit logs: 90-day retention.
	if n, err := db.PurgeOldAuditLogs(database, time.Now().Add(-90*24*time.Hour)); err != nil {
		slog.Error("audit log purge failed", "error", err)
	} else if n > 0 {
		slog.Info("purged old audit logs", "deleted", n)
	}

	// Refresh tokens: 7-day grace after expiry/revocation.
	if n, err := db.PurgeExpiredRefreshTokens(database, time.Now().Add(-7*24*time.Hour)); err != nil {
		slog.Error("refresh token purge failed", "error", err)
	} else if n > 0 {
		slog.Info("purged expired refresh tokens", "deleted", n)
	}

	// Expired commands: 7-day cutoff.
	if n, err := db.PurgeExpiredCommands(database, time.Now().Add(-7*24*time.Hour)); err != nil {
		slog.Error("command purge failed", "error", err)
	} else if n > 0 {
		slog.Info("purged expired commands", "deleted", n)
	}

	// App logs: 30-day retention.
	if n, err := db.PurgeOldAppLogs(database, time.Now().Add(-30*24*time.Hour)); err != nil {
		slog.Error("app log purge failed", "error", err)
	} else if n > 0 {
		slog.Info("purged old app logs", "deleted", n)
	}
}
