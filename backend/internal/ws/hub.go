package ws

import (
	"encoding/json"
	"fmt"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/AFK/afk-cloud/internal/model"
	"github.com/gorilla/websocket"
)

const remoteApprovalGracePeriod = 30 * time.Second

const maxConsecutiveDrops int64 = 50

// PushNotifier is the interface for sending push notifications from the WS layer.
// Defined here to avoid circular imports with the push package.
type PushNotifier interface {
	NotifyPermissionRequest(userID string, req model.PermissionRequest)
	NotifySessionError(userID, sessionID, errorMsg string)
	NotifySessionCompleted(userID, sessionID string)
	NotifySessionStopped(userID, sessionID, lastMessage string)
	NotifyIdlePrompt(userID, sessionID, message string)
	NotifyLiveActivityUpdate(sessionID, status, currentTool string, turnCount, elapsedSeconds int)
	RegisterLiveActivityToken(sessionID, pushToken string)
	DeregisterLiveActivityToken(sessionID string)
	TryPushToStartLiveActivity(userID, sessionID, projectName, deviceName string)
}

// PushDecisionEngine is the interface for intelligent push routing.
type PushDecisionEngine interface {
	HandleSessionEvent(userID, sessionID, eventType, deviceName string, data json.RawMessage)
	CleanupSession(sessionID string)
}

type AgentConn struct {
	DeviceID      string
	UserID        string
	Conn          *websocket.Conn
	Send          chan []byte
	droppedTotal  atomic.Int64
	droppedConsec atomic.Int64
}

type IOSConn struct {
	UserID        string
	DeviceID      string
	Conn          *websocket.Conn
	Send          chan []byte
	Subscriptions map[string]bool // sessionID -> subscribed
	mu            sync.Mutex
	droppedTotal  atomic.Int64
	droppedConsec atomic.Int64
}

func (c *IOSConn) SendMsg(msg *model.WSMessage) error {
	data, err := marshalMsg(msg)
	if err != nil {
		return err
	}
	select {
	case c.Send <- data:
		c.droppedConsec.Store(0)
		return nil
	default:
		total := c.droppedTotal.Add(1)
		consec := c.droppedConsec.Add(1)
		slog.Warn("iOS client dropped message",
			"user_id", c.UserID, "msg_type", msg.Type, "total_dropped", total, "consecutive", consec)
		return fmt.Errorf("iOS client send buffer full (consec=%d)", consec)
	}
}

type Hub struct {
	mu            sync.RWMutex
	agents        map[string]*AgentConn        // deviceID -> conn
	ios           map[string][]*IOSConn        // userID -> conns
	controlStates map[string]*model.WSMessage  // deviceID -> last agent.control_state
	usageStates   map[string]*model.WSMessage  // deviceID -> last agent.usage.update
	disableTimers map[string]*time.Timer       // userID -> pending remote approval disable
	Notifier      PushNotifier                 // optional push notification sender
	Decision      PushDecisionEngine           // optional intelligent push routing
}

func NewHub() *Hub {
	return &Hub{
		agents:        make(map[string]*AgentConn),
		ios:           make(map[string][]*IOSConn),
		controlStates: make(map[string]*model.WSMessage),
		usageStates:   make(map[string]*model.WSMessage),
		disableTimers: make(map[string]*time.Timer),
	}
}

func (h *Hub) RegisterAgent(deviceID, userID string, conn *websocket.Conn) *AgentConn {
	h.mu.Lock()
	defer h.mu.Unlock()

	// Close existing connection for this device if any.
	if existing, ok := h.agents[deviceID]; ok {
		close(existing.Send)
		existing.Conn.Close()
	}

	ac := &AgentConn{
		DeviceID: deviceID,
		UserID:   userID,
		Conn:     conn,
		Send:     make(chan []byte, 256),
	}
	h.agents[deviceID] = ac
	return ac
}

func (h *Hub) UnregisterAgent(deviceID string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if ac, ok := h.agents[deviceID]; ok {
		close(ac.Send)
		delete(h.agents, deviceID)
	}
	delete(h.controlStates, deviceID)
	delete(h.usageStates, deviceID)
}

func (h *Hub) RegisterIOS(userID, deviceID string, conn *websocket.Conn) *IOSConn {
	h.mu.Lock()
	defer h.mu.Unlock()

	// Cancel any pending remote approval disable for this user,
	// since an iOS client just reconnected (e.g., coming back from background).
	if timer, ok := h.disableTimers[userID]; ok {
		timer.Stop()
		delete(h.disableTimers, userID)
		slog.Info("iOS reconnected within grace period, cancelled remote approval disable", "user_id", userID)
	}

	ic := &IOSConn{
		UserID:        userID,
		DeviceID:      deviceID,
		Conn:          conn,
		Send:          make(chan []byte, 256),
		Subscriptions: make(map[string]bool),
	}
	h.ios[userID] = append(h.ios[userID], ic)
	return ic
}

func (h *Hub) UnregisterIOS(userID string, conn *IOSConn) {
	h.mu.Lock()
	defer h.mu.Unlock()

	conns := h.ios[userID]
	for i, c := range conns {
		if c == conn {
			close(c.Send)
			h.ios[userID] = append(conns[:i], conns[i+1:]...)
			break
		}
	}
	if len(h.ios[userID]) == 0 {
		delete(h.ios, userID)
	}
}

// HasIOSDeviceConn returns true if at least one iOS connection exists for the given deviceID.
func (h *Hub) HasIOSDeviceConn(userID, deviceID string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, c := range h.ios[userID] {
		if c.DeviceID == deviceID {
			return true
		}
	}
	return false
}

func (h *Hub) BroadcastToUser(userID string, msg *model.WSMessage) {
	h.mu.RLock()
	original := h.ios[userID]
	conns := make([]*IOSConn, len(original))
	copy(conns, original)
	h.mu.RUnlock()

	if len(conns) == 0 {
		slog.Warn("broadcast to user with no iOS connections",
			"msg_type", msg.Type, "user_id", userID)
	}

	var toEvict []*IOSConn
	for _, c := range conns {
		if err := c.SendMsg(msg); err != nil {
			if c.droppedConsec.Load() >= maxConsecutiveDrops {
				toEvict = append(toEvict, c)
			}
		}
	}

	for _, c := range toEvict {
		slog.Warn("evicting slow iOS client",
			"user_id", c.UserID, "consecutive", c.droppedConsec.Load())
		h.UnregisterIOS(userID, c)
		c.Conn.Close()
	}
}

// BroadcastToAll sends a message to ALL connections for a user: iOS and agents.
// Use for events that all peers need to know about (e.g., key rotation).
func (h *Hub) BroadcastToAll(userID string, msg *model.WSMessage) {
	// Send to iOS connections
	h.BroadcastToUser(userID, msg)

	// Also send to all agent connections for this user
	h.mu.RLock()
	var userAgents []*AgentConn
	for _, ac := range h.agents {
		if ac.UserID == userID {
			userAgents = append(userAgents, ac)
		}
	}
	h.mu.RUnlock()

	data, err := marshalMsg(msg)
	if err != nil {
		slog.Error("failed to marshal broadcast message for agents", "error", err)
		return
	}

	for _, ac := range userAgents {
		select {
		case ac.Send <- data:
			ac.droppedConsec.Store(0)
		default:
			total := ac.droppedTotal.Add(1)
			consec := ac.droppedConsec.Add(1)
			slog.Warn("agent dropped broadcast message",
				"device_id", ac.DeviceID, "msg_type", msg.Type, "total_dropped", total, "consecutive", consec)
		}
	}

	slog.Info("broadcast sent to user",
		"msg_type", msg.Type, "user_id", userID, "ios_conns", len(h.ios[userID]), "agent_conns", len(userAgents))
}

// DisconnectUserAgents force-closes all agent connections for a user.
// Used after user migration to make agents reconnect under the new user.
func (h *Hub) DisconnectUserAgents(userID string) {
	h.mu.RLock()
	var toClose []*AgentConn
	for _, ac := range h.agents {
		if ac.UserID == userID {
			toClose = append(toClose, ac)
		}
	}
	h.mu.RUnlock()

	for _, ac := range toClose {
		slog.Info("force-disconnecting agent for user migration", "device_id", ac.DeviceID)
		ac.Conn.Close()
	}
}

func (h *Hub) GetAgentConn(deviceID string) *AgentConn {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.agents[deviceID]
}

// GetOnlineAgentForUser returns the first online agent connection for a user, or nil if none.
func (h *Hub) GetOnlineAgentForUser(userID string) *AgentConn {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, ac := range h.agents {
		if ac.UserID == userID {
			return ac
		}
	}
	return nil
}

func (h *Hub) SendToAgent(deviceID string, msg *model.WSMessage) error {
	h.mu.RLock()
	ac := h.agents[deviceID]
	h.mu.RUnlock()
	if ac == nil {
		return fmt.Errorf("agent %s not connected", deviceID)
	}
	data, err := marshalMsg(msg)
	if err != nil {
		return err
	}
	select {
	case ac.Send <- data:
		ac.droppedConsec.Store(0)
		return nil
	default:
		total := ac.droppedTotal.Add(1)
		consec := ac.droppedConsec.Add(1)
		slog.Warn("agent send buffer full, dropped message",
			"device_id", deviceID, "msg_type", msg.Type, "total_dropped", total, "consecutive", consec)
		return fmt.Errorf("agent %s send buffer full", deviceID)
	}
}

// HasActiveIOSConns returns true if the user has at least one active iOS WebSocket connection.
func (h *Hub) HasActiveIOSConns(userID string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.ios[userID]) > 0
}

// ScheduleRemoteApprovalDisable schedules disabling remote approval for all
// agents of a user after a grace period. If an iOS client reconnects before
// the timer fires (e.g., app returning from background), RegisterIOS cancels it.
func (h *Hub) ScheduleRemoteApprovalDisable(userID string) {
	h.mu.Lock()
	defer h.mu.Unlock()

	// If a timer already exists, let it run (don't reset).
	if _, ok := h.disableTimers[userID]; ok {
		return
	}

	slog.Info("scheduling remote approval disable after grace period",
		"user_id", userID, "grace_period", remoteApprovalGracePeriod)

	h.disableTimers[userID] = time.AfterFunc(remoteApprovalGracePeriod, func() {
		h.mu.Lock()
		delete(h.disableTimers, userID)
		h.mu.Unlock()

		// Re-check: iOS may have reconnected between timer creation and firing.
		if h.HasActiveIOSConns(userID) {
			slog.Info("iOS reconnected before grace period expired, skipping disable", "user_id", userID)
			return
		}

		ra := false
		disableMsg, err := NewWSMessage("agent_control", struct {
			RemoteApproval *bool `json:"remoteApproval"`
		}{&ra})
		if err == nil {
			h.SendToUserAgents(userID, disableMsg)
			slog.Info("grace period expired, disabled remote approval for all agents", "user_id", userID)
		}
	})
}

// SendToUserAgents sends a message to all agent connections for a user.
func (h *Hub) SendToUserAgents(userID string, msg *model.WSMessage) {
	h.mu.RLock()
	var userAgents []*AgentConn
	for _, ac := range h.agents {
		if ac.UserID == userID {
			userAgents = append(userAgents, ac)
		}
	}
	h.mu.RUnlock()

	data, err := marshalMsg(msg)
	if err != nil {
		return
	}
	for _, ac := range userAgents {
		select {
		case ac.Send <- data:
			ac.droppedConsec.Store(0)
		default:
			ac.droppedTotal.Add(1)
			ac.droppedConsec.Add(1)
		}
	}
}

// CacheControlState stores the last agent.control_state message for a device.
func (h *Hub) CacheControlState(deviceID string, msg *model.WSMessage) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.controlStates[deviceID] = msg
}

// SendCachedControlStates replays cached agent.control_state messages for
// the user's online agents to a newly connected iOS client.
func (h *Hub) SendCachedControlStates(userID string, ic *IOSConn) {
	h.mu.RLock()
	var msgs []*model.WSMessage
	for deviceID, ac := range h.agents {
		if ac.UserID == userID {
			if msg, ok := h.controlStates[deviceID]; ok {
				msgs = append(msgs, msg)
			}
		}
	}
	h.mu.RUnlock()

	for _, msg := range msgs {
		_ = ic.SendMsg(msg)
	}
}

// CacheUsageState stores the last agent.usage.update message for a device.
func (h *Hub) CacheUsageState(deviceID string, msg *model.WSMessage) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.usageStates[deviceID] = msg
}

// SendCachedUsageStates replays cached agent.usage.update messages for
// the user's online agents to a newly connected iOS client.
func (h *Hub) SendCachedUsageStates(userID string, ic *IOSConn) {
	h.mu.RLock()
	var msgs []*model.WSMessage
	for deviceID, ac := range h.agents {
		if ac.UserID == userID {
			if msg, ok := h.usageStates[deviceID]; ok {
				msgs = append(msgs, msg)
			}
		}
	}
	h.mu.RUnlock()

	for _, msg := range msgs {
		_ = ic.SendMsg(msg)
	}
}

// ConnectionCounts returns the number of agent and iOS connections.
func (h *Hub) ConnectionCounts() (agents int, ios int) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	agentCount := len(h.agents)
	iosCount := 0
	for _, conns := range h.ios {
		iosCount += len(conns)
	}
	return agentCount, iosCount
}

// Shutdown gracefully closes all WebSocket connections with a close frame.
func (h *Hub) Shutdown() {
	h.mu.Lock()
	defer h.mu.Unlock()

	closeMsg := websocket.FormatCloseMessage(websocket.CloseGoingAway, "server shutting down")

	for id, ac := range h.agents {
		ac.Conn.WriteMessage(websocket.CloseMessage, closeMsg)
		ac.Conn.Close()
		// Don't close(ac.Send) — the write pump will exit when conn.Close()
		// causes its WriteMessage to fail. Closing the channel here races
		// with a write pump that hasn't exited yet.
		delete(h.agents, id)
	}

	for userID, conns := range h.ios {
		for _, c := range conns {
			c.Conn.WriteMessage(websocket.CloseMessage, closeMsg)
			c.Conn.Close()
		}
		delete(h.ios, userID)
	}

	for userID, timer := range h.disableTimers {
		timer.Stop()
		delete(h.disableTimers, userID)
	}

	slog.Info("hub shutdown complete")
}

func marshalMsg(msg *model.WSMessage) ([]byte, error) {
	return json.Marshal(msg)
}
