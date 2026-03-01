package push

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	apnsProductionURL  = "https://api.push.apple.com"
	apnsDevelopmentURL = "https://api.sandbox.push.apple.com"
	tokenTTL           = 50 * time.Minute // APNs tokens valid for 1h, refresh at 50m
)

// APNsClient sends push notifications via Apple's HTTP/2 APNs API.
// Uses token-based (.p8) authentication with Go's standard net/http client.
type APNsClient struct {
	httpClient *http.Client
	baseURL    string
	bundleID   string
	keyID      string
	teamID     string
	privateKey *ecdsa.PrivateKey

	mu         sync.RWMutex
	bearerToken string
	tokenExpiry time.Time

	enabled bool
}

// NewAPNsClient creates an APNs client from config.
// If keyPath is empty, returns a no-op client that logs instead of sending.
func NewAPNsClient(keyPath, keyID, teamID, bundleID string, production bool) (*APNsClient, error) {
	if keyPath == "" {
		slog.Info("APNs key not configured, push notifications disabled")
		return &APNsClient{enabled: false}, nil
	}

	keyData, err := os.ReadFile(keyPath)
	if err != nil {
		return nil, fmt.Errorf("read APNs key file: %w", err)
	}

	block, _ := pem.Decode(keyData)
	if block == nil {
		return nil, fmt.Errorf("failed to decode PEM block from APNs key")
	}

	key, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse APNs private key: %w", err)
	}

	ecKey, ok := key.(*ecdsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("APNs key is not ECDSA")
	}

	baseURL := apnsDevelopmentURL
	if production {
		baseURL = apnsProductionURL
	}

	client := &APNsClient{
		httpClient: &http.Client{Timeout: 30 * time.Second},
		baseURL:    baseURL,
		bundleID:   bundleID,
		keyID:      keyID,
		teamID:     teamID,
		privateKey: ecKey,
		enabled:    true,
	}

	env := "sandbox"
	if production {
		env = "production"
	}
	slog.Info("APNs client initialized", "env", env, "key_id", keyID, "team_id", teamID, "bundle_id", bundleID)
	return client, nil
}

// SendNotification sends a visible push notification.
// threadID groups notifications on the iOS lock screen (set to sessionId for per-session grouping).
func (c *APNsClient) SendNotification(deviceToken, title, body, category, threadID string, data map[string]string) error {
	if !c.enabled {
		slog.Debug("no-op: would send notification", "device_token", deviceToken[:8], "title", title, "body", body)
		return nil
	}

	aps := map[string]interface{}{
		"alert": map[string]string{
			"title": title,
			"body":  body,
		},
		"sound":    "default",
		"category": category,
	}
	if threadID != "" {
		aps["thread-id"] = threadID
	}

	payload := map[string]interface{}{
		"aps": aps,
	}
	for k, v := range data {
		payload[k] = v
	}

	return c.send(deviceToken, payload, false)
}

// SendSilent sends a silent/background push notification.
func (c *APNsClient) SendSilent(deviceToken string, data map[string]string) error {
	if !c.enabled {
		slog.Debug("no-op: would send silent push", "device_token", deviceToken[:8])
		return nil
	}

	payload := map[string]interface{}{
		"aps": map[string]interface{}{
			"content-available": 1,
		},
	}
	for k, v := range data {
		payload[k] = v
	}

	return c.send(deviceToken, payload, true)
}

// SendLiveActivityUpdate sends a Live Activity push update with ContentState data.
func (c *APNsClient) SendLiveActivityUpdate(pushToken string, contentState map[string]interface{}) error {
	if !c.enabled {
		slog.Debug("no-op: would send live activity update", "push_token", pushToken[:min(8, len(pushToken))])
		return nil
	}

	payload := map[string]interface{}{
		"aps": map[string]interface{}{
			"timestamp":     time.Now().Unix(),
			"event":         "update",
			"content-state": contentState,
		},
	}
	return c.sendLiveActivity(pushToken, payload)
}

// SendLiveActivityStart sends a push-to-start Live Activity (iOS 17.2+).
// This creates a new Live Activity remotely even when the app is not running.
func (c *APNsClient) SendLiveActivityStart(pushToStartToken string, sessionID, projectName, deviceName string) error {
	if !c.enabled {
		slog.Debug("no-op: would send live activity push-to-start", "push_token", pushToStartToken[:min(8, len(pushToStartToken))], "session_id", sessionID)
		return nil
	}

	payload := map[string]interface{}{
		"aps": map[string]interface{}{
			"timestamp":       time.Now().Unix(),
			"event":           "start",
			"attributes-type": "SessionActivityAttributes",
			"attributes": map[string]interface{}{
				"sessionId":   sessionID,
				"projectName": projectName,
				"deviceName":  deviceName,
			},
			"content-state": map[string]interface{}{
				"status":         "running",
				"turnCount":      0,
				"elapsedSeconds": 0,
			},
			"alert": map[string]interface{}{
				"title": "Session Started",
				"body":  projectName + " is running on " + deviceName,
			},
		},
	}

	slog.Info("sending push-to-start payload", "session_id", sessionID, "project_name", projectName, "device_name", deviceName)

	return c.sendLiveActivity(pushToStartToken, payload)
}

// SendLiveActivityEnd sends a Live Activity end push.
func (c *APNsClient) SendLiveActivityEnd(pushToken string, contentState map[string]interface{}) error {
	if !c.enabled {
		slog.Debug("no-op: would send live activity end", "push_token", pushToken[:min(8, len(pushToken))])
		return nil
	}

	payload := map[string]interface{}{
		"aps": map[string]interface{}{
			"timestamp":      time.Now().Unix(),
			"event":          "end",
			"dismissal-date": time.Now().Add(5 * time.Minute).Unix(),
			"content-state":  contentState,
		},
	}
	return c.sendLiveActivity(pushToken, payload)
}

func (c *APNsClient) sendLiveActivity(pushToken string, payload map[string]interface{}) error {
	jsonBody, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshal APNs LA payload: %w", err)
	}

	url := fmt.Sprintf("%s/3/device/%s", c.baseURL, pushToken)
	req, err := http.NewRequest("POST", url, bytes.NewReader(jsonBody))
	if err != nil {
		return fmt.Errorf("create APNs LA request: %w", err)
	}

	token, err := c.getBearerToken()
	if err != nil {
		return fmt.Errorf("get bearer token: %w", err)
	}

	req.Header.Set("Authorization", "bearer "+token)
	req.Header.Set("apns-topic", c.bundleID+".push-type.liveactivity")
	req.Header.Set("apns-push-type", "liveactivity")
	req.Header.Set("apns-priority", "10")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("send APNs LA request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusOK {
		apnsID := resp.Header.Get("apns-id")
		slog.Info("live activity push accepted", "apns_id", apnsID, "push_token", pushToken[:min(8, len(pushToken))])
		return nil
	}

	respBody, _ := io.ReadAll(resp.Body)
	slog.Error("live activity push failed", "status_code", resp.StatusCode, "push_token", pushToken[:min(8, len(pushToken))], "response", string(respBody))

	if resp.StatusCode == http.StatusGone {
		return &APNsError{StatusCode: resp.StatusCode, Reason: "Unregistered"}
	}

	return fmt.Errorf("APNs LA returned status %d: %s", resp.StatusCode, string(respBody))
}

// IsGone returns true if the APNs response indicates the token is no longer valid.
func IsGone(statusCode int) bool {
	return statusCode == http.StatusGone
}

func (c *APNsClient) send(deviceToken string, payload map[string]interface{}, silent bool) error {
	jsonBody, err := json.Marshal(payload)
	if err != nil {
		return fmt.Errorf("marshal APNs payload: %w", err)
	}

	url := fmt.Sprintf("%s/3/device/%s", c.baseURL, deviceToken)
	req, err := http.NewRequest("POST", url, bytes.NewReader(jsonBody))
	if err != nil {
		return fmt.Errorf("create APNs request: %w", err)
	}

	token, err := c.getBearerToken()
	if err != nil {
		return fmt.Errorf("get bearer token: %w", err)
	}

	req.Header.Set("Authorization", "bearer "+token)
	req.Header.Set("apns-topic", c.bundleID)
	req.Header.Set("apns-push-type", pushType(silent))
	if !silent {
		req.Header.Set("apns-priority", "10")
	} else {
		req.Header.Set("apns-priority", "5")
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("send APNs request: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusOK {
		return nil
	}

	respBody, _ := io.ReadAll(resp.Body)
	slog.Error("APNs error response", "status_code", resp.StatusCode, "response", string(respBody))

	if resp.StatusCode == http.StatusGone {
		return &APNsError{StatusCode: resp.StatusCode, Reason: "Unregistered"}
	}

	return fmt.Errorf("APNs returned status %d: %s", resp.StatusCode, string(respBody))
}

func (c *APNsClient) getBearerToken() (string, error) {
	c.mu.RLock()
	if c.bearerToken != "" && time.Now().Before(c.tokenExpiry) {
		token := c.bearerToken
		c.mu.RUnlock()
		return token, nil
	}
	c.mu.RUnlock()

	c.mu.Lock()
	defer c.mu.Unlock()

	// Double-check after acquiring write lock.
	if c.bearerToken != "" && time.Now().Before(c.tokenExpiry) {
		return c.bearerToken, nil
	}

	now := time.Now()
	claims := jwt.MapClaims{
		"iss": c.teamID,
		"iat": now.Unix(),
	}
	token := jwt.NewWithClaims(jwt.SigningMethodES256, claims)
	token.Header["kid"] = c.keyID

	signed, err := token.SignedString(c.privateKey)
	if err != nil {
		return "", fmt.Errorf("sign APNs JWT: %w", err)
	}

	c.bearerToken = signed
	c.tokenExpiry = now.Add(tokenTTL)
	return signed, nil
}

func pushType(silent bool) string {
	if silent {
		return "background"
	}
	return "alert"
}

// APNsError represents an error from APNs with a status code.
type APNsError struct {
	StatusCode int
	Reason     string
}

func (e *APNsError) Error() string {
	return fmt.Sprintf("APNs error %d: %s", e.StatusCode, e.Reason)
}
