package ws

import (
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/AFK/afk-cloud/internal/model"
	"github.com/gorilla/websocket"
)

// dialWS upgrades an httptest.Server to a real WebSocket connection.
func dialWS(t *testing.T, srv *httptest.Server) *websocket.Conn {
	t.Helper()
	wsURL := "ws" + srv.URL[4:] // http -> ws
	c, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	return c
}

// wsEchoServer returns a test server that accepts and holds a WebSocket conn.
// The returned channel receives the server-side *websocket.Conn.
func wsEchoServer(t *testing.T) (*httptest.Server, chan *websocket.Conn) {
	t.Helper()
	ch := make(chan *websocket.Conn, 1)
	upgrader := websocket.Upgrader{CheckOrigin: func(r *http.Request) bool { return true }}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Errorf("upgrade: %v", err)
			return
		}
		ch <- c
	}))
	t.Cleanup(srv.Close)
	return srv, ch
}

// serverConn creates a real WebSocket pair and returns the server-side conn.
func serverConn(t *testing.T) *websocket.Conn {
	t.Helper()
	srv, ch := wsEchoServer(t)
	client := dialWS(t, srv)
	t.Cleanup(func() { client.Close() })
	serverC := <-ch
	return serverC
}

func testMsg(msgType string) *model.WSMessage {
	return &model.WSMessage{
		Type:      msgType,
		Payload:   json.RawMessage(`{"test":true}`),
		Timestamp: time.Now().Unix(),
	}
}

// =============================================================================
// RegisterAgent / UnregisterAgent
// =============================================================================

func TestRegisterAgent_Basic(t *testing.T) {
	hub := NewHub()
	conn := serverConn(t)

	ac := hub.RegisterAgent("dev-1", "user-1", conn)
	if ac == nil {
		t.Fatal("RegisterAgent returned nil")
	}
	if ac.DeviceID != "dev-1" {
		t.Errorf("DeviceID = %q, want %q", ac.DeviceID, "dev-1")
	}
	if ac.UserID != "user-1" {
		t.Errorf("UserID = %q, want %q", ac.UserID, "user-1")
	}

	got := hub.GetAgentConn("dev-1")
	if got != ac {
		t.Error("GetAgentConn should return the registered conn")
	}
}

func TestRegisterAgent_ReRegistrationClosesOldConn(t *testing.T) {
	hub := NewHub()
	conn1 := serverConn(t)
	conn2 := serverConn(t)

	ac1 := hub.RegisterAgent("dev-1", "user-1", conn1)
	ac2 := hub.RegisterAgent("dev-1", "user-1", conn2)

	// ac1.Send should be closed by re-registration.
	_, ok := <-ac1.Send
	if ok {
		t.Error("old agent's Send channel should be closed after re-registration")
	}

	got := hub.GetAgentConn("dev-1")
	if got != ac2 {
		t.Error("GetAgentConn should return the new conn")
	}
}

func TestUnregisterAgent(t *testing.T) {
	hub := NewHub()
	conn := serverConn(t)

	hub.RegisterAgent("dev-1", "user-1", conn)
	hub.UnregisterAgent("dev-1")

	if hub.GetAgentConn("dev-1") != nil {
		t.Error("agent should be removed after unregister")
	}
}

func TestUnregisterAgent_ClearsControlState(t *testing.T) {
	hub := NewHub()
	conn := serverConn(t)

	hub.RegisterAgent("dev-1", "user-1", conn)
	hub.CacheControlState("dev-1", testMsg("agent.control_state"))
	hub.UnregisterAgent("dev-1")

	// controlStates should be cleaned up.
	hub.mu.RLock()
	_, exists := hub.controlStates["dev-1"]
	hub.mu.RUnlock()
	if exists {
		t.Error("control state should be cleared after unregister")
	}
}

func TestUnregisterAgent_Idempotent(t *testing.T) {
	hub := NewHub()
	// Should not panic on double unregister.
	hub.UnregisterAgent("nonexistent")
	hub.UnregisterAgent("nonexistent")
}

// =============================================================================
// RegisterIOS / UnregisterIOS
// =============================================================================

func TestRegisterIOS_Basic(t *testing.T) {
	hub := NewHub()
	conn := serverConn(t)

	ic := hub.RegisterIOS("user-1", "",conn)
	if ic == nil {
		t.Fatal("RegisterIOS returned nil")
	}
	if ic.UserID != "user-1" {
		t.Errorf("UserID = %q, want %q", ic.UserID, "user-1")
	}
	if !hub.HasActiveIOSConns("user-1") {
		t.Error("HasActiveIOSConns should return true after register")
	}
}

func TestRegisterIOS_MultipleConns(t *testing.T) {
	hub := NewHub()
	conn1 := serverConn(t)
	conn2 := serverConn(t)

	ic1 := hub.RegisterIOS("user-1", "",conn1)
	ic2 := hub.RegisterIOS("user-1", "",conn2)

	if ic1 == ic2 {
		t.Error("two registrations should yield different IOSConn pointers")
	}

	agents, ios := hub.ConnectionCounts()
	if agents != 0 || ios != 2 {
		t.Errorf("ConnectionCounts = (%d, %d), want (0, 2)", agents, ios)
	}
}

func TestUnregisterIOS(t *testing.T) {
	hub := NewHub()
	conn := serverConn(t)

	ic := hub.RegisterIOS("user-1", "",conn)
	hub.UnregisterIOS("user-1", ic)

	if hub.HasActiveIOSConns("user-1") {
		t.Error("HasActiveIOSConns should be false after unregister")
	}
}

func TestUnregisterIOS_RemovesCorrectConn(t *testing.T) {
	hub := NewHub()
	conn1 := serverConn(t)
	conn2 := serverConn(t)

	ic1 := hub.RegisterIOS("user-1", "",conn1)
	hub.RegisterIOS("user-1", "",conn2)

	hub.UnregisterIOS("user-1", ic1)

	_, ios := hub.ConnectionCounts()
	if ios != 1 {
		t.Errorf("ios count = %d, want 1", ios)
	}
	if !hub.HasActiveIOSConns("user-1") {
		t.Error("HasActiveIOSConns should still be true (one conn remains)")
	}
}

// =============================================================================
// BroadcastToUser
// =============================================================================

func TestBroadcastToUser_DeliversToAllIOSConns(t *testing.T) {
	hub := NewHub()
	conn1 := serverConn(t)
	conn2 := serverConn(t)

	ic1 := hub.RegisterIOS("user-1", "",conn1)
	ic2 := hub.RegisterIOS("user-1", "",conn2)

	msg := testMsg("test.event")
	hub.BroadcastToUser("user-1", msg)

	// Both conns should have received the message with correct type.
	for _, pair := range []struct {
		name string
		ch   chan []byte
	}{{"ic1", ic1.Send}, {"ic2", ic2.Send}} {
		select {
		case data := <-pair.ch:
			var got model.WSMessage
			if err := json.Unmarshal(data, &got); err != nil {
				t.Errorf("%s: unmarshal: %v", pair.name, err)
			} else if got.Type != "test.event" {
				t.Errorf("%s: Type = %q, want %q", pair.name, got.Type, "test.event")
			}
		case <-time.After(time.Second):
			t.Errorf("%s did not receive message", pair.name)
		}
	}
}

func TestBroadcastToUser_NoConns(t *testing.T) {
	hub := NewHub()
	// Should not panic when broadcasting to user with no connections.
	hub.BroadcastToUser("nobody", testMsg("test"))
}

// =============================================================================
// SendToAgent
// =============================================================================

func TestSendToAgent_Success(t *testing.T) {
	hub := NewHub()
	conn := serverConn(t)

	ac := hub.RegisterAgent("dev-1", "user-1", conn)
	err := hub.SendToAgent("dev-1", testMsg("command.deliver"))
	if err != nil {
		t.Fatalf("SendToAgent failed: %v", err)
	}

	select {
	case data := <-ac.Send:
		var got model.WSMessage
		if err := json.Unmarshal(data, &got); err != nil {
			t.Errorf("unmarshal: %v", err)
		} else if got.Type != "command.deliver" {
			t.Errorf("Type = %q, want %q", got.Type, "command.deliver")
		}
	case <-time.After(time.Second):
		t.Error("agent did not receive message")
	}
}

func TestSendToAgent_NotConnected(t *testing.T) {
	hub := NewHub()
	err := hub.SendToAgent("nonexistent", testMsg("test"))
	if err == nil {
		t.Error("SendToAgent should fail for unconnected agent")
	}
}

func TestSendToAgent_BufferFull(t *testing.T) {
	hub := NewHub()
	conn := serverConn(t)

	hub.RegisterAgent("dev-1", "user-1", conn)

	// Fill the 256-slot buffer.
	msg := testMsg("fill")
	for i := 0; i < 256; i++ {
		if err := hub.SendToAgent("dev-1", msg); err != nil {
			t.Fatalf("SendToAgent failed on message %d: %v", i, err)
		}
	}

	// 257th should fail.
	err := hub.SendToAgent("dev-1", msg)
	if err == nil {
		t.Error("SendToAgent should fail when buffer is full")
	}
}

// =============================================================================
// Message drop counting and eviction
// =============================================================================

func TestIOSConn_SendMsg_DropsCountOnFullBuffer(t *testing.T) {
	ic := &IOSConn{
		UserID: "user-1",
		Send:   make(chan []byte, 1), // tiny buffer
	}

	msg := testMsg("test")

	// First message succeeds.
	if err := ic.SendMsg(msg); err != nil {
		t.Fatalf("first SendMsg should succeed: %v", err)
	}

	// Second message should be dropped.
	err := ic.SendMsg(msg)
	if err == nil {
		t.Error("SendMsg should fail on full buffer")
	}

	if ic.droppedTotal.Load() != 1 {
		t.Errorf("droppedTotal = %d, want 1", ic.droppedTotal.Load())
	}
	if ic.droppedConsec.Load() != 1 {
		t.Errorf("droppedConsec = %d, want 1", ic.droppedConsec.Load())
	}
}

func TestIOSConn_SendMsg_ResetsConsecOnSuccess(t *testing.T) {
	ic := &IOSConn{
		UserID: "user-1",
		Send:   make(chan []byte, 2),
	}

	msg := testMsg("test")

	// Artificially set dropped counts.
	ic.droppedConsec.Store(10)
	ic.droppedTotal.Store(10)

	if err := ic.SendMsg(msg); err != nil {
		t.Fatal(err)
	}

	if ic.droppedConsec.Load() != 0 {
		t.Errorf("droppedConsec should reset to 0 on success, got %d", ic.droppedConsec.Load())
	}
	// Total is not reset.
	if ic.droppedTotal.Load() != 10 {
		t.Errorf("droppedTotal should remain 10, got %d", ic.droppedTotal.Load())
	}
}

func TestBroadcastToUser_EvictsSlowClient(t *testing.T) {
	hub := NewHub()
	conn := serverConn(t)

	ic := hub.RegisterIOS("user-1", "",conn)

	// Artificially set consecutive drops just below threshold.
	ic.droppedConsec.Store(maxConsecutiveDrops - 1)

	// Fill the send buffer completely.
	for i := 0; i < cap(ic.Send); i++ {
		ic.Send <- []byte(`{}`)
	}

	// This broadcast should trigger eviction (buffer full + consec hits 50).
	hub.BroadcastToUser("user-1", testMsg("trigger-evict"))

	if hub.HasActiveIOSConns("user-1") {
		t.Error("slow iOS client should have been evicted")
	}
}

// =============================================================================
// BroadcastToAll
// =============================================================================

func TestBroadcastToAll_SendsToIOSAndAgents(t *testing.T) {
	hub := NewHub()
	agentConn := serverConn(t)
	iosConn := serverConn(t)

	ac := hub.RegisterAgent("dev-1", "user-1", agentConn)
	ic := hub.RegisterIOS("user-1", "",iosConn)

	hub.BroadcastToAll("user-1", testMsg("device.key_rotated"))

	for _, pair := range []struct {
		name string
		ch   chan []byte
	}{{"ios", ic.Send}, {"agent", ac.Send}} {
		select {
		case data := <-pair.ch:
			var got model.WSMessage
			if err := json.Unmarshal(data, &got); err != nil {
				t.Errorf("%s: unmarshal: %v", pair.name, err)
			} else if got.Type != "device.key_rotated" {
				t.Errorf("%s: Type = %q, want %q", pair.name, got.Type, "device.key_rotated")
			}
		case <-time.After(time.Second):
			t.Errorf("%s did not receive broadcast", pair.name)
		}
	}
}

func TestBroadcastToAll_OnlySendsToCorrectUser(t *testing.T) {
	hub := NewHub()
	conn1 := serverConn(t)
	conn2 := serverConn(t)

	hub.RegisterAgent("dev-1", "user-1", conn1)
	ac2 := hub.RegisterAgent("dev-2", "user-2", conn2)

	hub.BroadcastToAll("user-1", testMsg("event"))

	// user-2's agent should NOT receive the message.
	select {
	case <-ac2.Send:
		t.Error("user-2's agent should not receive user-1's broadcast")
	case <-time.After(50 * time.Millisecond):
		// expected
	}
}

// =============================================================================
// CacheControlState / SendCachedControlStates
// =============================================================================

func TestCacheControlState_And_Replay(t *testing.T) {
	hub := NewHub()
	conn := serverConn(t)

	hub.RegisterAgent("dev-1", "user-1", conn)
	msg := testMsg("agent.control_state")
	hub.CacheControlState("dev-1", msg)

	// Create an iOS conn and replay cached states.
	iosConn := serverConn(t)
	ic := hub.RegisterIOS("user-1", "",iosConn)
	hub.SendCachedControlStates("user-1", ic)

	select {
	case data := <-ic.Send:
		var got model.WSMessage
		if err := json.Unmarshal(data, &got); err != nil {
			t.Errorf("unmarshal: %v", err)
		} else if got.Type != "agent.control_state" {
			t.Errorf("Type = %q, want %q", got.Type, "agent.control_state")
		}
	case <-time.After(time.Second):
		t.Error("iOS conn should receive cached control state")
	}
}

func TestSendCachedControlStates_NoAgents(t *testing.T) {
	hub := NewHub()
	iosConn := serverConn(t)
	ic := hub.RegisterIOS("user-1", "",iosConn)

	// Should not panic when no agents are registered.
	hub.SendCachedControlStates("user-1", ic)

	select {
	case <-ic.Send:
		t.Error("should not receive any cached states when no agents exist")
	case <-time.After(50 * time.Millisecond):
		// expected
	}
}

func TestSendCachedControlStates_OnlyForSameUser(t *testing.T) {
	hub := NewHub()
	conn1 := serverConn(t)
	conn2 := serverConn(t)

	hub.RegisterAgent("dev-1", "user-1", conn1)
	hub.RegisterAgent("dev-2", "user-2", conn2)
	hub.CacheControlState("dev-1", testMsg("state-user1"))
	hub.CacheControlState("dev-2", testMsg("state-user2"))

	iosConn := serverConn(t)
	ic := hub.RegisterIOS("user-1", "",iosConn)
	hub.SendCachedControlStates("user-1", ic)

	// Should only get one message (user-1's agent).
	select {
	case <-ic.Send:
	case <-time.After(time.Second):
		t.Fatal("expected one cached state")
	}

	select {
	case <-ic.Send:
		t.Error("should not receive user-2's cached state")
	case <-time.After(50 * time.Millisecond):
		// expected
	}
}

// =============================================================================
// HasActiveIOSConns
// =============================================================================

func TestHasActiveIOSConns(t *testing.T) {
	hub := NewHub()

	if hub.HasActiveIOSConns("user-1") {
		t.Error("should return false for unknown user")
	}

	conn := serverConn(t)
	ic := hub.RegisterIOS("user-1", "",conn)

	if !hub.HasActiveIOSConns("user-1") {
		t.Error("should return true after registration")
	}

	hub.UnregisterIOS("user-1", ic)

	if hub.HasActiveIOSConns("user-1") {
		t.Error("should return false after last conn unregistered")
	}
}

// =============================================================================
// GetAgentConn / GetOnlineAgentForUser
// =============================================================================

func TestGetAgentConn_NotFound(t *testing.T) {
	hub := NewHub()
	if hub.GetAgentConn("nonexistent") != nil {
		t.Error("should return nil for unknown device")
	}
}

func TestGetOnlineAgentForUser(t *testing.T) {
	hub := NewHub()

	if hub.GetOnlineAgentForUser("user-1") != nil {
		t.Error("should return nil when no agents registered")
	}

	conn := serverConn(t)
	ac := hub.RegisterAgent("dev-1", "user-1", conn)

	got := hub.GetOnlineAgentForUser("user-1")
	if got != ac {
		t.Error("should return registered agent for user")
	}

	if hub.GetOnlineAgentForUser("user-2") != nil {
		t.Error("should return nil for different user")
	}
}

// =============================================================================
// ConnectionCounts
// =============================================================================

func TestConnectionCounts(t *testing.T) {
	hub := NewHub()

	agents, ios := hub.ConnectionCounts()
	if agents != 0 || ios != 0 {
		t.Errorf("empty hub: agents=%d, ios=%d, want (0, 0)", agents, ios)
	}

	conn1 := serverConn(t)
	conn2 := serverConn(t)
	conn3 := serverConn(t)

	hub.RegisterAgent("dev-1", "user-1", conn1)
	hub.RegisterIOS("user-1", "",conn2)
	hub.RegisterIOS("user-2", "",conn3)

	agents, ios = hub.ConnectionCounts()
	if agents != 1 || ios != 2 {
		t.Errorf("agents=%d, ios=%d, want (1, 2)", agents, ios)
	}
}

// =============================================================================
// DisconnectUserAgents
// =============================================================================

func TestDisconnectUserAgents(t *testing.T) {
	hub := NewHub()
	conn1 := serverConn(t)
	conn2 := serverConn(t)

	hub.RegisterAgent("dev-1", "user-1", conn1)
	hub.RegisterAgent("dev-2", "user-1", conn2)

	hub.DisconnectUserAgents("user-1")

	// The connections are closed but the entries remain in the map
	// (the real write pump would call UnregisterAgent on conn close).
	// Verify the underlying connections were closed by attempting to write.
	err := conn1.WriteMessage(websocket.PingMessage, nil)
	if err == nil {
		t.Error("conn1 should be closed after DisconnectUserAgents")
	}
	err = conn2.WriteMessage(websocket.PingMessage, nil)
	if err == nil {
		t.Error("conn2 should be closed after DisconnectUserAgents")
	}
}

func TestDisconnectUserAgents_DoesNotAffectOtherUsers(t *testing.T) {
	hub := NewHub()
	conn1 := serverConn(t)
	conn2 := serverConn(t)

	hub.RegisterAgent("dev-1", "user-1", conn1)
	hub.RegisterAgent("dev-2", "user-2", conn2)

	hub.DisconnectUserAgents("user-1")

	// user-2's agent should still be reachable.
	err := hub.SendToAgent("dev-2", testMsg("ping"))
	if err != nil {
		t.Errorf("user-2's agent should not be affected: %v", err)
	}
}

// =============================================================================
// Concurrency safety
// =============================================================================

func TestHub_ConcurrentAccess(t *testing.T) {
	hub := NewHub()
	var wg sync.WaitGroup

	// Spin up goroutines that register, send, and unregister concurrently.
	// Each goroutine uses a unique device ID to avoid send-on-closed-channel
	// panics (UnregisterAgent closes the Send channel, and SendToAgent writes
	// to it without holding the lock for the entire operation).
	for i := 0; i < 20; i++ {
		devID := fmt.Sprintf("concurrent-dev-%d", i)
		wg.Add(1)
		go func() {
			defer wg.Done()
			// Create a local WebSocket pair for this goroutine.
			ln, err := net.Listen("tcp", "127.0.0.1:0")
			if err != nil {
				t.Errorf("goroutine %s: listen failed: %v", devID, err)
				return
			}
			defer ln.Close()

			upgrader := websocket.Upgrader{CheckOrigin: func(r *http.Request) bool { return true }}
			srvDone := make(chan *websocket.Conn, 1)
			srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				c, err := upgrader.Upgrade(w, r, nil)
				if err != nil {
					return
				}
				srvDone <- c
			})}
			go srv.Serve(ln)
			defer srv.Close()

			client, _, err := websocket.DefaultDialer.Dial("ws://"+ln.Addr().String(), nil)
			if err != nil {
				t.Errorf("goroutine %s: dial failed: %v", devID, err)
				return
			}
			defer client.Close()

			sc := <-srvDone

			hub.RegisterAgent(devID, "user-1", sc)
			hub.SendToAgent(devID, testMsg("ping"))
			hub.GetAgentConn(devID)
			hub.HasActiveIOSConns("user-1")
			hub.ConnectionCounts()
			hub.UnregisterAgent(devID)
		}()
	}

	wg.Wait()
}

// =============================================================================
// Shutdown
// =============================================================================

func TestHub_Shutdown(t *testing.T) {
	hub := NewHub()
	agentConn := serverConn(t)
	iosConn := serverConn(t)

	hub.RegisterAgent("dev-1", "user-1", agentConn)
	hub.RegisterIOS("user-1", "",iosConn)

	hub.Shutdown()

	agents, ios := hub.ConnectionCounts()
	if agents != 0 {
		t.Errorf("agents after shutdown = %d, want 0", agents)
	}
	if ios != 0 {
		t.Errorf("ios after shutdown = %d, want 0", ios)
	}

	// Verify the underlying connections were closed.
	err := agentConn.WriteMessage(websocket.PingMessage, nil)
	if err == nil {
		t.Error("agent conn should be closed after shutdown")
	}
	err = iosConn.WriteMessage(websocket.PingMessage, nil)
	if err == nil {
		t.Error("iOS conn should be closed after shutdown")
	}
}

func TestHub_Shutdown_Empty(t *testing.T) {
	hub := NewHub()
	// Should not panic on empty hub.
	hub.Shutdown()

	agents, ios := hub.ConnectionCounts()
	if agents != 0 || ios != 0 {
		t.Errorf("expected (0, 0), got (%d, %d)", agents, ios)
	}
}

// =============================================================================
// Edge cases
// =============================================================================

func TestSendCachedControlStates_AgentWithNoCachedState(t *testing.T) {
	hub := NewHub()
	conn := serverConn(t)

	// Agent registered but no CacheControlState call.
	hub.RegisterAgent("dev-1", "user-1", conn)

	iosConn := serverConn(t)
	ic := hub.RegisterIOS("user-1", "",iosConn)
	hub.SendCachedControlStates("user-1", ic)

	select {
	case <-ic.Send:
		t.Error("should not receive cached state when none was cached")
	case <-time.After(50 * time.Millisecond):
		// expected
	}
}
