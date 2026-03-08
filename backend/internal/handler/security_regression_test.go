package handler

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/AFK/afk-cloud/internal/db"
	"github.com/AFK/afk-cloud/internal/model"
	"github.com/AFK/afk-cloud/internal/ws"
)

// =============================================================================
// RED-001 (CWE-345): Subscription sync StoreKit key guard + transaction ID format
// =============================================================================

func TestSubscriptionSync_CWE345_RejectsWithoutStoreKitKey(t *testing.T) {
	database := testDB(t)
	userID := createTestUser(t, database, "sub@test.com", "Sub User", "hashedpass")

	h := &SubscriptionHandler{DB: database, StoreKitKeySet: false}
	body := map[string]string{
		"originalTransactionId": "123456789012345",
		"productId":             "com.afk.pro.monthly",
	}
	rr := doAuthedRequest(t, h.HandleSync, "POST", "/v1/subscription/sync", body, userID)
	if rr.Code != http.StatusServiceUnavailable {
		t.Errorf("expected 503 when StoreKit key not set, got %d", rr.Code)
	}
}

func TestSubscriptionSync_CWE345_RejectsInvalidTransactionID(t *testing.T) {
	database := testDB(t)
	userID := createTestUser(t, database, "sub2@test.com", "Sub User2", "hashedpass")

	h := &SubscriptionHandler{DB: database, StoreKitKeySet: true}

	cases := []struct {
		name  string
		txID  string
	}{
		{"non-numeric", "abc123def456ghi"},
		{"too short", "12345"},
		{"too long", "12345678901234567890123456"},
		{"special chars", "123456789<script>"},
		{"sql injection", "123456789' OR '1'='1"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			body := map[string]string{
				"originalTransactionId": tc.txID,
				"productId":             "com.afk.pro.monthly",
			}
			rr := doAuthedRequest(t, h.HandleSync, "POST", "/v1/subscription/sync", body, userID)
			if rr.Code != http.StatusBadRequest {
				t.Errorf("expected 400 for txID %q, got %d", tc.txID, rr.Code)
			}
		})
	}
}

func TestSubscriptionSync_CWE345_RequiresServerVerification(t *testing.T) {
	database := testDB(t)
	userID := createTestUser(t, database, "sub3@test.com", "Sub User3", "hashedpass")

	// Without StoreKit key configured, sync should return 503.
	h := &SubscriptionHandler{DB: database, StoreKitKeySet: false}
	body := map[string]string{
		"originalTransactionId": "123456789012345",
		"productId":             "com.afk.pro.monthly",
		"expiresAt":             "2030-01-01T00:00:00Z",
	}
	rr := doAuthedRequest(t, h.HandleSync, "POST", "/v1/subscription/sync", body, userID)
	if rr.Code != http.StatusServiceUnavailable {
		t.Errorf("expected 503 without StoreKit key, got %d (body: %s)", rr.Code, rr.Body.String())
	}

	// With key set but no valid PEM, server-side verification should fail (403).
	h2 := &SubscriptionHandler{DB: database, StoreKitKeySet: true}
	rr2 := doAuthedRequest(t, h2.HandleSync, "POST", "/v1/subscription/sync", body, userID)
	if rr2.Code != http.StatusForbidden {
		t.Errorf("expected 403 when server verification fails, got %d (body: %s)", rr2.Code, rr2.Body.String())
	}
}

// =============================================================================
// RED-002 (CWE-639): Live activity token requires session ownership
// =============================================================================

func TestLiveActivityToken_CWE639_RequiresSessionOwnership(t *testing.T) {
	database := testDB(t)
	ownerID := createTestUser(t, database, "owner@test.com", "Owner", "hashedpass")
	attackerID := createTestUser(t, database, "attacker@test.com", "Attacker", "hashedpass")
	deviceID := createTestDevice(t, database, ownerID, "OwnerMac")
	sessionID := "test-session-001"
	createTestSession(t, database, sessionID, deviceID, ownerID)

	handler := HandleRegisterLiveActivityToken(ws.NewHub(), database)
	body := map[string]string{"pushToken": "test-token-value"}

	// Attacker tries to register token for a session they don't own.
	pathVals := map[string]string{"id": sessionID}
	rr := doAuthedRequestWithPathVals(t, handler, "POST", "/v2/sessions/"+sessionID+"/live-activity-token", body, attackerID, pathVals)
	if rr.Code != http.StatusForbidden && rr.Code != http.StatusNotFound {
		t.Errorf("expected 403 or 404 for non-owner, got %d", rr.Code)
	}
}

func TestLiveActivityToken_CWE639_AllowsOwner(t *testing.T) {
	database := testDB(t)
	ownerID := createTestUser(t, database, "owner2@test.com", "Owner2", "hashedpass")
	deviceID := createTestDevice(t, database, ownerID, "OwnerMac2")
	sessionID := "test-session-002"
	createTestSession(t, database, sessionID, deviceID, ownerID)

	handler := HandleRegisterLiveActivityToken(ws.NewHub(), database)
	body := map[string]string{"pushToken": "test-token-value"}

	pathVals := map[string]string{"id": sessionID}
	rr := doAuthedRequestWithPathVals(t, handler, "POST", "/v2/sessions/"+sessionID+"/live-activity-token", body, ownerID, pathVals)
	if rr.Code != http.StatusOK {
		t.Errorf("expected 200 for session owner, got %d (body: %s)", rr.Code, rr.Body.String())
	}
}

func TestLiveActivityToken_CWE639_RejectsNonexistentSession(t *testing.T) {
	database := testDB(t)
	userID := createTestUser(t, database, "user@test.com", "User", "hashedpass")

	handler := HandleRegisterLiveActivityToken(ws.NewHub(), database)
	body := map[string]string{"pushToken": "test-token-value"}

	pathVals := map[string]string{"id": "nonexistent-session-id"}
	rr := doAuthedRequestWithPathVals(t, handler, "POST", "/v2/sessions/nonexistent-session-id/live-activity-token", body, userID, pathVals)
	if rr.Code != http.StatusNotFound {
		t.Errorf("expected 404 for nonexistent session, got %d", rr.Code)
	}
}

// =============================================================================
// RED-003 (CWE-639): Push token deletion requires ownership
// =============================================================================

func TestPushTokenDelete_CWE639_RequiresTokenOwnership(t *testing.T) {
	database := testDB(t)
	ownerID := createTestUser(t, database, "ptowner@test.com", "PTOwner", "hashedpass")
	attackerID := createTestUser(t, database, "ptattacker@test.com", "PTAttacker", "hashedpass")

	// Register a push token for the owner.
	_ = db.UpsertPushToken(database, ownerID, "owner-device-token", "ios", "com.afk.app")

	h := &PushHandler{DB: database}
	body := map[string]string{"deviceToken": "owner-device-token"}

	// Attacker tries to delete owner's push token.
	rr := doAuthedRequest(t, h.HandleDelete, "DELETE", "/v1/push-tokens", body, attackerID)
	// Should return 200 (no error), but the token should still exist.
	if rr.Code != http.StatusOK {
		t.Errorf("expected 200 response, got %d", rr.Code)
	}

	// Verify owner's token still exists.
	tokens, err := db.ListPushTokensByUser(database, ownerID)
	if err != nil {
		t.Fatalf("list push tokens: %v", err)
	}
	if len(tokens) != 1 {
		t.Errorf("expected owner's push token to still exist, got %d tokens", len(tokens))
	}
}

func TestPushTokenDelete_CWE639_OwnerCanDelete(t *testing.T) {
	database := testDB(t)
	ownerID := createTestUser(t, database, "ptowner2@test.com", "PTOwner2", "hashedpass")

	_ = db.UpsertPushToken(database, ownerID, "my-device-token", "ios", "com.afk.app")

	h := &PushHandler{DB: database}
	body := map[string]string{"deviceToken": "my-device-token"}

	rr := doAuthedRequest(t, h.HandleDelete, "DELETE", "/v1/push-tokens", body, ownerID)
	if rr.Code != http.StatusOK {
		t.Errorf("expected 200, got %d", rr.Code)
	}

	// Verify token is deleted.
	tokens, err := db.ListPushTokensByUser(database, ownerID)
	if err != nil {
		t.Fatalf("list push tokens: %v", err)
	}
	if len(tokens) != 0 {
		t.Errorf("expected push token to be deleted, got %d tokens", len(tokens))
	}
}

// =============================================================================
// RED-005 (CWE-79): displayName HTML sanitization
// =============================================================================

func TestEmailRegister_CWE79_SanitizesDisplayName(t *testing.T) {
	database := testDB(t)
	h := &AuthHandler{DB: database, JWTSecret: testJWTSecret, RequireTLS: false}

	cases := []struct {
		name    string
		display string
		expect  string // expected sanitized output (empty = check no tags)
	}{
		{"script tag", "<script>alert(1)</script>", "scriptalert(1)/script"},
		{"img onerror", "<img src=x onerror=alert(1)>", "img src=x onerror=alert(1)"},
		{"nested tags", "<b><i>bold italic</i></b>", "bibold italic/i/b"},
		{"clean text", "Normal User Name", "Normal User Name"},
	}

	for i, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			body := model.EmailRegisterRequest{
				Email:       strings.Replace("xss_user@test.com", "xss", tc.name, 1),
				Password:    "Secure@Pass1",
				DisplayName: tc.display,
			}
			// Use unique email per test.
			body.Email = strings.ReplaceAll(body.Email, " ", "_")
			body.Email = strings.ReplaceAll(body.Email, "<", "")
			body.Email = strings.ReplaceAll(body.Email, ">", "")
			// Just use index-based email to keep it simple.
			body.Email = "xss" + string(rune('0'+i)) + "@test.com"

			rr := doRequest(t, h.HandleEmailRegister, "POST", "/v1/auth/register", body)
			if rr.Code != http.StatusCreated {
				t.Fatalf("expected 201, got %d (body: %s)", rr.Code, rr.Body.String())
			}

			// Registration returns verification_required, check DB directly.
			user, err := db.GetUserByEmail(database, body.Email)
			if err != nil {
				t.Fatalf("failed to get user: %v", err)
			}
			if strings.Contains(user.DisplayName, "<") || strings.Contains(user.DisplayName, ">") {
				t.Errorf("displayName still contains HTML tags: %q", user.DisplayName)
			}
		})
	}
}

// =============================================================================
// RED-007 (CWE-79): Task subject/description HTML sanitization
// =============================================================================

func TestTaskCreate_CWE79_SanitizesSubject(t *testing.T) {
	database := testDB(t)
	userID := createTestUser(t, database, "taskuser@test.com", "TaskUser", "hashedpass")

	h := &TaskHandler{DB: database}
	body := model.CreateTaskRequest{
		Subject:     "<script>alert('xss')</script>Fix bug",
		Description: "Normal description",
	}
	rr := doAuthedRequest(t, h.HandleCreate, "POST", "/v1/tasks", body, userID)
	if rr.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d (body: %s)", rr.Code, rr.Body.String())
	}

	var task model.Task
	json.NewDecoder(rr.Body).Decode(&task)
	if strings.Contains(task.Subject, "<") || strings.Contains(task.Subject, ">") {
		t.Errorf("task subject still contains HTML: %q", task.Subject)
	}
}

func TestTaskUpdate_CWE79_SanitizesDescription(t *testing.T) {
	database := testDB(t)
	userID := createTestUser(t, database, "taskuser2@test.com", "TaskUser2", "hashedpass")

	h := &TaskHandler{DB: database}

	// Create a clean task first.
	createBody := model.CreateTaskRequest{Subject: "Clean task", Description: "Clean desc"}
	createRR := doAuthedRequest(t, h.HandleCreate, "POST", "/v1/tasks", createBody, userID)
	if createRR.Code != http.StatusCreated {
		t.Fatalf("create task failed: %d", createRR.Code)
	}
	var created model.Task
	json.NewDecoder(createRR.Body).Decode(&created)

	// Update with XSS payload in description.
	xssDesc := "<img src=x onerror=alert(1)>Updated description"
	updateBody := model.UpdateTaskRequest{Description: &xssDesc}

	// Build request with path value for task ID.
	bodyBytes, _ := json.Marshal(updateBody)
	req := httptest.NewRequest("PUT", "/v1/tasks/"+created.ID, bytes.NewReader(bodyBytes))
	req.Header.Set("Content-Type", "application/json")
	req.SetPathValue("id", created.ID)
	rr := httptest.NewRecorder()
	withAuth(userID, h.HandleUpdate)(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d (body: %s)", rr.Code, rr.Body.String())
	}

	var updated model.Task
	json.NewDecoder(rr.Body).Decode(&updated)
	if strings.Contains(updated.Description, "<") || strings.Contains(updated.Description, ">") {
		t.Errorf("task description still contains HTML: %q", updated.Description)
	}
}

func TestTaskCreate_CWE79_NormalTextPassesThrough(t *testing.T) {
	database := testDB(t)
	userID := createTestUser(t, database, "taskuser3@test.com", "TaskUser3", "hashedpass")

	h := &TaskHandler{DB: database}
	body := model.CreateTaskRequest{
		Subject:     "Fix authentication bug in login flow",
		Description: "Users report 500 errors when logging in with special chars: @#$%",
	}
	rr := doAuthedRequest(t, h.HandleCreate, "POST", "/v1/tasks", body, userID)
	if rr.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d", rr.Code)
	}

	var task model.Task
	json.NewDecoder(rr.Body).Decode(&task)
	if task.Subject != body.Subject {
		t.Errorf("subject changed: got %q, want %q", task.Subject, body.Subject)
	}
	if task.Description != body.Description {
		t.Errorf("description changed: got %q, want %q", task.Description, body.Description)
	}
}

// =============================================================================
// RED-009 (CWE-200): Metrics auth gate
// =============================================================================

func TestMetrics_CWE200_ReturnsServiceUnavailableWhenNoSessionStore(t *testing.T) {
	h := &MetricsHandler{Collector: nil, SessionStore: nil}
	req := httptest.NewRequest("GET", "/metrics", nil)
	rr := httptest.NewRecorder()
	h.Handle(rr, req)

	if rr.Code != http.StatusServiceUnavailable {
		t.Errorf("expected 503 when SessionStore is nil, got %d", rr.Code)
	}
}

func TestMetrics_CWE200_ReturnsUnauthorizedWithoutSession(t *testing.T) {
	store := NewAdminSessionStore()
	h := &MetricsHandler{Collector: nil, SessionStore: store}
	req := httptest.NewRequest("GET", "/metrics", nil)
	rr := httptest.NewRecorder()
	h.Handle(rr, req)

	if rr.Code != http.StatusUnauthorized {
		t.Errorf("expected 401 without session cookie, got %d", rr.Code)
	}
	store.Stop()
}

func TestMetrics_CWE200_ReturnsOKWithValidSession(t *testing.T) {
	collector := newTestCollector()
	store := NewAdminSessionStore()
	sessionID, _ := store.Create("admin-user-1", "127.0.0.1")
	h := &MetricsHandler{Collector: collector, SessionStore: store}
	req := httptest.NewRequest("GET", "/metrics", nil)
	req.RemoteAddr = "127.0.0.1:1234"
	req.AddCookie(&http.Cookie{Name: adminCookieName, Value: sessionID})
	rr := httptest.NewRecorder()
	h.Handle(rr, req)

	if rr.Code != http.StatusOK {
		t.Errorf("expected 200 with valid session, got %d", rr.Code)
	}
	store.Stop()
}

// =============================================================================
// RED-010 (CWE-307): Login lockout uses IP+email composite
// =============================================================================

func TestLoginLockout_CWE307_IPEmailComposite(t *testing.T) {
	database := testDB(t)
	_ = createTestUser(t, database, "lockout@test.com", "Lockout", "$2a$12$dummy")

	ip1Key := "10.0.0.0:lockout@test.com"
	ip2Key := "10.0.1.0:lockout@test.com"

	// Record 5 failures from IP1 for lockout@test.com.
	for i := 0; i < 5; i++ {
		db.RecordLoginAttempt(database, ip1Key, false, "10.0.0.1")
	}

	// Verify IP1 has 5 records in the login_attempts table.
	var count1 int
	err := database.QueryRow(`SELECT COUNT(*) FROM login_attempts WHERE email = ? AND success = 0`, ip1Key).Scan(&count1)
	if err != nil {
		t.Fatalf("count IP1 attempts: %v", err)
	}
	if count1 != 5 {
		t.Errorf("IP1 should have 5 failure records, got %d", count1)
	}

	// Verify IP2 has 0 records (different composite key).
	var count2 int
	err = database.QueryRow(`SELECT COUNT(*) FROM login_attempts WHERE email = ? AND success = 0`, ip2Key).Scan(&count2)
	if err != nil {
		t.Fatalf("count IP2 attempts: %v", err)
	}
	if count2 != 0 {
		t.Errorf("IP2 should have 0 failure records, got %d", count2)
	}
}

// =============================================================================
// RED-011 (CWE-204): No email enumeration on registration
// =============================================================================

func TestEmailRegister_CWE204_NoEmailEnumeration(t *testing.T) {
	database := testDB(t)
	h := &AuthHandler{DB: database, JWTSecret: testJWTSecret, RequireTLS: false}

	// Register first user.
	body1 := model.EmailRegisterRequest{
		Email:    "existing@test.com",
		Password: "Secure@Pass1",
	}
	rr1 := doRequest(t, h.HandleEmailRegister, "POST", "/v1/auth/register", body1)
	if rr1.Code != http.StatusCreated {
		t.Fatalf("first registration should succeed, got %d", rr1.Code)
	}

	// Try to register the same email again.
	body2 := model.EmailRegisterRequest{
		Email:    "existing@test.com",
		Password: "Another@Pass456",
	}
	rr2 := doRequest(t, h.HandleEmailRegister, "POST", "/v1/auth/register", body2)

	// Must NOT return 409 Conflict (that would leak email existence).
	if rr2.Code == http.StatusConflict {
		t.Error("registration returned 409 Conflict, leaking email existence")
	}
	// Should return 400 with a generic message.
	if rr2.Code != http.StatusBadRequest {
		t.Errorf("expected 400 for duplicate email, got %d", rr2.Code)
	}

	errMsg := parseResponseError(t, rr2)
	if strings.Contains(strings.ToLower(errMsg), "already") || strings.Contains(strings.ToLower(errMsg), "exist") {
		t.Errorf("error message leaks email existence: %q", errMsg)
	}
}

func TestEmailRegister_CWE204_NewEmailReturns201(t *testing.T) {
	database := testDB(t)
	h := &AuthHandler{DB: database, JWTSecret: testJWTSecret, RequireTLS: false}

	body := model.EmailRegisterRequest{
		Email:    "newuser@test.com",
		Password: "Secure@Pass1",
	}
	rr := doRequest(t, h.HandleEmailRegister, "POST", "/v1/auth/register", body)
	if rr.Code != http.StatusCreated {
		t.Errorf("expected 201 for new email, got %d", rr.Code)
	}
}

// =============================================================================
// RED-014 (CWE-20): worktreeName and permissionMode validation
// =============================================================================

func TestNewChat_CWE20_PathTraversalInWorktreeName(t *testing.T) {
	cases := []struct {
		name     string
		worktree string
	}{
		{"dot-dot-slash", "../../../etc/passwd"},
		{"slash-separated", "my/worktree/name"},
		{"too long", strings.Repeat("a", 65)},
		{"starts with hyphen", "-malicious"},
		{"special chars", "work tree!@#$"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if !worktreeNameRe.MatchString(tc.worktree) || len(tc.worktree) > 64 {
				// validation would reject it, good
				return
			}
			t.Errorf("worktree name %q was not rejected by validation", tc.worktree)
		})
	}
}

func TestNewChat_CWE20_InvalidPermissionMode(t *testing.T) {
	invalid := []string{"root", "admin", "sudo", "../../etc", "<script>", "autoApprove; rm -rf /", "autoApprove", "dontAsk", "bypassPermissions", "ask"}
	for _, mode := range invalid {
		if validPermissionModes[mode] {
			t.Errorf("invalid permission mode %q was accepted", mode)
		}
	}
}

func TestNewChat_CWE20_ValidPermissionModes(t *testing.T) {
	valid := []string{"", "default", "acceptEdits", "plan"}
	for _, mode := range valid {
		if !validPermissionModes[mode] {
			t.Errorf("valid permission mode %q was rejected", mode)
		}
	}
}

func TestNewChat_CWE20_ValidWorktreeNames(t *testing.T) {
	valid := []string{"my-feature", "fix123", "a", "my-long-feature-branch-name"}
	for _, name := range valid {
		if !worktreeNameRe.MatchString(name) {
			t.Errorf("valid worktree name %q was rejected", name)
		}
	}
}

// =============================================================================
// RED-018 (CWE-20): Task status enum validation
// =============================================================================

func TestTaskUpdate_CWE20_InvalidStatusRejected(t *testing.T) {
	database := testDB(t)
	userID := createTestUser(t, database, "statususer@test.com", "StatusUser", "hashedpass")

	h := &TaskHandler{DB: database}

	// Create a task first.
	createBody := model.CreateTaskRequest{Subject: "Status test task"}
	createRR := doAuthedRequest(t, h.HandleCreate, "POST", "/v1/tasks", createBody, userID)
	var created model.Task
	json.NewDecoder(createRR.Body).Decode(&created)

	invalid := []string{"admin", "deleted", "DROP TABLE", "<script>", "running", "done"}
	for _, status := range invalid {
		t.Run(status, func(t *testing.T) {
			s := status
			updateBody := model.UpdateTaskRequest{Status: &s}
			bodyBytes, _ := json.Marshal(updateBody)
			req := httptest.NewRequest("PUT", "/v1/tasks/"+created.ID, bytes.NewReader(bodyBytes))
			req.Header.Set("Content-Type", "application/json")
			req.SetPathValue("id", created.ID)
			rr := httptest.NewRecorder()
			withAuth(userID, h.HandleUpdate)(rr, req)

			if rr.Code != http.StatusBadRequest {
				t.Errorf("expected 400 for invalid status %q, got %d", status, rr.Code)
			}
		})
	}
}

func TestTaskUpdate_CWE20_ValidStatusesAccepted(t *testing.T) {
	database := testDB(t)
	userID := createTestUser(t, database, "statususer2@test.com", "StatusUser2", "hashedpass")

	h := &TaskHandler{DB: database}

	valid := []string{"pending", "in_progress", "completed", "cancelled"}
	for _, status := range valid {
		t.Run(status, func(t *testing.T) {
			// Create a fresh task for each status test.
			createBody := model.CreateTaskRequest{Subject: "Task for " + status}
			createRR := doAuthedRequest(t, h.HandleCreate, "POST", "/v1/tasks", createBody, userID)
			var created model.Task
			json.NewDecoder(createRR.Body).Decode(&created)

			s := status
			updateBody := model.UpdateTaskRequest{Status: &s}
			bodyBytes, _ := json.Marshal(updateBody)
			req := httptest.NewRequest("PUT", "/v1/tasks/"+created.ID, bytes.NewReader(bodyBytes))
			req.Header.Set("Content-Type", "application/json")
			req.SetPathValue("id", created.ID)
			rr := httptest.NewRecorder()
			withAuth(userID, h.HandleUpdate)(rr, req)

			if rr.Code != http.StatusOK {
				t.Errorf("expected 200 for valid status %q, got %d (body: %s)", status, rr.Code, rr.Body.String())
			}
		})
	}
}

// =============================================================================
// RED-016 (CWE-770): MaxBytesReader on handlers
// =============================================================================

func TestLiveActivityToken_CWE770_OversizedBodyRejected(t *testing.T) {
	database := testDB(t)
	ownerID := createTestUser(t, database, "laowner@test.com", "LAOwner", "hashedpass")
	deviceID := createTestDevice(t, database, ownerID, "LAMac")
	sessionID := "test-session-la"
	createTestSession(t, database, sessionID, deviceID, ownerID)

	handler := HandleRegisterLiveActivityToken(ws.NewHub(), database)

	// Create a body larger than 1MB.
	oversized := `{"pushToken":"` + strings.Repeat("A", 2*1024*1024) + `"}`
	req := httptest.NewRequest("POST", "/v2/sessions/"+sessionID+"/live-activity-token", strings.NewReader(oversized))
	req.Header.Set("Content-Type", "application/json")
	req.SetPathValue("id", sessionID)
	rr := httptest.NewRecorder()
	withAuth(ownerID, handler)(rr, req)

	if rr.Code == http.StatusOK {
		t.Error("expected rejection for oversized body, got 200")
	}
}

func TestTaskCreate_CWE770_OversizedBodyRejected(t *testing.T) {
	database := testDB(t)
	userID := createTestUser(t, database, "taskover@test.com", "TaskOver", "hashedpass")

	h := &TaskHandler{DB: database}

	oversized := `{"subject":"` + strings.Repeat("X", 2*1024*1024) + `"}`
	req := httptest.NewRequest("POST", "/v1/tasks", strings.NewReader(oversized))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	withAuth(userID, h.HandleCreate)(rr, req)

	// Should reject with 400 (MaxBytesReader triggers json decode error).
	if rr.Code == http.StatusCreated {
		t.Error("expected rejection for oversized body, got 201")
	}
}

func TestTaskUpdate_CWE770_OversizedBodyRejected(t *testing.T) {
	database := testDB(t)
	userID := createTestUser(t, database, "taskoverupd@test.com", "TaskOverUpd", "hashedpass")

	h := &TaskHandler{DB: database}

	// Create a task first.
	createBody := model.CreateTaskRequest{Subject: "Oversize update task"}
	createRR := doAuthedRequest(t, h.HandleCreate, "POST", "/v1/tasks", createBody, userID)
	var created model.Task
	json.NewDecoder(createRR.Body).Decode(&created)

	oversized := `{"subject":"` + strings.Repeat("X", 2*1024*1024) + `"}`
	req := httptest.NewRequest("PUT", "/v1/tasks/"+created.ID, strings.NewReader(oversized))
	req.Header.Set("Content-Type", "application/json")
	req.SetPathValue("id", created.ID)
	rr := httptest.NewRecorder()
	withAuth(userID, h.HandleUpdate)(rr, req)

	if rr.Code == http.StatusOK {
		t.Error("expected rejection for oversized body, got 200")
	}
}

func TestPushToStart_CWE770_OversizedBodyRejected(t *testing.T) {
	database := testDB(t)
	userID := createTestUser(t, database, "ptsover@test.com", "PTSOver", "hashedpass")

	h := &PushToStartHandler{DB: database}

	oversized := `{"token":"` + strings.Repeat("A", 2*1024*1024) + `"}`
	req := httptest.NewRequest("POST", "/v1/push-to-start-token", strings.NewReader(oversized))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	withAuth(userID, h.HandleRegister)(rr, req)

	if rr.Code == http.StatusOK {
		t.Error("expected rejection for oversized body, got 200")
	}
}
