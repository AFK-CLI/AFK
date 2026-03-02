package config

import (
	"fmt"
	"log/slog"
	"os"
	"strings"

	"github.com/joho/godotenv"
)

type Config struct {
	Port             string
	DatabasePath     string
	JWTSecret        string
	AppleBundleIDs   []string
	ServerPublicKey  string // hex-encoded Ed25519 public key
	ServerPrivateKey string // hex-encoded Ed25519 private key
	APNsKeyPath      string // path to .p8 file
	APNsKeyID        string
	APNsTeamID       string
	APNsBundleID     string
	APNsProduction   bool   // true = api.push.apple.com, false = api.sandbox.push.apple.com
	LogLevel         string
	AdminSecret      string
	TrustedProxies   []string
}

func Load() *Config {
	// Load .env file if present (does not override existing env vars).
	if err := godotenv.Load(); err != nil {
		slog.Info("no .env file found, using environment variables")
	}

	return &Config{
		Port:             getEnv("AFK_PORT", "9847"),
		DatabasePath:     getEnv("AFK_DB_PATH", "afk.db"),
		JWTSecret:        getEnv("AFK_JWT_SECRET", ""),
		AppleBundleIDs:   splitCSV(getEnv("AFK_APPLE_BUNDLE_ID", "com.afk.app")),
		ServerPublicKey:  getEnv("AFK_SERVER_PUBLIC_KEY", ""),
		ServerPrivateKey: getEnv("AFK_SERVER_PRIVATE_KEY", ""),
		APNsKeyPath:      getEnv("AFK_APNS_KEY_PATH", ""),
		APNsKeyID:        getEnv("AFK_APNS_KEY_ID", ""),
		APNsTeamID:       getEnv("AFK_APNS_TEAM_ID", ""),
		APNsBundleID:     getEnv("AFK_APNS_BUNDLE_ID", ""),
		APNsProduction:   getEnv("AFK_APNS_PRODUCTION", "") == "1",
		LogLevel:         getEnv("AFK_LOG_LEVEL", "info"),
		AdminSecret:      getEnv("AFK_ADMIN_SECRET", ""),
		TrustedProxies:   splitCSV(getEnv("AFK_TRUSTED_PROXIES", "")),
	}
}

func (c *Config) Validate() error {
	if c.JWTSecret == "" {
		return fmt.Errorf("AFK_JWT_SECRET is required — generate one with: openssl rand -hex 32")
	}
	if c.JWTSecret == "dev-secret-change-in-production" {
		return fmt.Errorf("AFK_JWT_SECRET still set to insecure default — generate a real secret with: openssl rand -hex 32")
	}
	if len(c.JWTSecret) < 32 {
		return fmt.Errorf("AFK_JWT_SECRET must be at least 32 characters — generate one with: openssl rand -hex 32")
	}
	if c.AdminSecret != "" && len(c.AdminSecret) < 32 {
		return fmt.Errorf("AFK_ADMIN_SECRET must be at least 32 characters when set — generate one with: openssl rand -hex 32")
	}
	return nil
}

// SetupLogging configures the global slog logger based on LogLevel and AFK_LOG_FORMAT.
// JSON format by default, text format when AFK_LOG_FORMAT=text.
func (c *Config) SetupLogging() {
	var level slog.Level
	switch strings.ToLower(c.LogLevel) {
	case "debug":
		level = slog.LevelDebug
	case "warn", "warning":
		level = slog.LevelWarn
	case "error":
		level = slog.LevelError
	default:
		level = slog.LevelInfo
	}

	opts := &slog.HandlerOptions{Level: level}

	var handler slog.Handler
	if os.Getenv("AFK_LOG_FORMAT") == "text" {
		handler = slog.NewTextHandler(os.Stderr, opts)
	} else {
		handler = slog.NewJSONHandler(os.Stderr, opts)
	}

	slog.SetDefault(slog.New(handler))
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func splitCSV(s string) []string {
	parts := strings.Split(s, ",")
	result := make([]string, 0, len(parts))
	for _, p := range parts {
		if t := strings.TrimSpace(p); t != "" {
			result = append(result, t)
		}
	}
	return result
}
