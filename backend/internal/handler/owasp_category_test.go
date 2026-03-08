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
// OWASP API1:2023 (BOLA) — Object-Level Authorization on session/user scoped endpoints
// Covers: RED-002, RED-003
// =============================================================================

func TestAPI1_BOLA_SessionScopedEndpoints(t *testing.T) {
	database := testDB(t)
	ownerID := createTestUser(t, database, "bola_owner@test.com", "Owner", "hashedpass")
	attackerID := createTestUser(t, database, "bola_attacker@test.com", "Attacker", "hashedpass")
	deviceID := createTestDevice(t, database, ownerID, "OwnerDevice")
	sessionID := "bola-session-001"
	createTestSession(t, database, sessionID, deviceID, ownerID)

	// Test: Live Activity token registration (session-scoped).
	t.Run("LiveActivityToken_SessionOwnership", func(t *testing.T) {
		handler := HandleRegisterLiveActivityToken(ws.NewHub(), database)
		body := map[string]string{"pushToken": "bola-test-token"}
		pathVals := map[string]string{"id": sessionID}
		rr := doAuthedRequestWithPathVals(t, handler, "POST", "/v2/sessions/"+sessionID+"/live-activity-token", body, attackerID, pathVals)
		if rr.Code == http.StatusOK {
			t.Error("attacker should not be able to register live activity token for another user's session")
		}
	})

	// Test: Push token deletion (user-scoped).
	t.Run("PushTokenDeletion_UserScoped", func(t *testing.T) {
		_ = db.UpsertPushToken(database, ownerID, "bola-push-token", "ios", "com.afk.app")

		h := &PushHandler{DB: database}
		body := map[string]string{"deviceToken": "bola-push-token"}
		rr := doAuthedRequest(t, h.HandleDelete, "DELETE", "/v1/push-tokens", body, attackerID)

		// Verify attacker could not delete owner's token.
		tokens, _ := db.ListPushTokensByUser(database, ownerID)
		if len(tokens) == 0 {
			t.Error("attacker was able to delete owner's push token (BOLA vulnerability)")
		}
		_ = rr
	})

	// Test: Task update ownership check.
	t.Run("TaskUpdate_OwnershipCheck", func(t *testing.T) {
		h := &TaskHandler{DB: database}
		createBody := model.CreateTaskRequest{Subject: "BOLA task"}
		createRR := doAuthedRequest(t, h.HandleCreate, "POST", "/v1/tasks", createBody, ownerID)
		var created model.Task
		json.NewDecoder(createRR.Body).Decode(&created)

		// Attacker tries to update owner's task.
		newSubject := "Hacked"
		updateBody := model.UpdateTaskRequest{Subject: &newSubject}
		bodyBytes, _ := json.Marshal(updateBody)
		req := httptest.NewRequest("PUT", "/v1/tasks/"+created.ID, bytes.NewReader(bodyBytes))
		req.Header.Set("Content-Type", "application/json")
		req.SetPathValue("id", created.ID)
		rr := httptest.NewRecorder()
		withAuth(attackerID, h.HandleUpdate)(rr, req)

		if rr.Code == http.StatusOK {
			t.Error("attacker should not be able to update owner's task (BOLA)")
		}
	})

	// Test: Task delete ownership check.
	t.Run("TaskDelete_OwnershipCheck", func(t *testing.T) {
		h := &TaskHandler{DB: database}
		createBody := model.CreateTaskRequest{Subject: "BOLA delete task"}
		createRR := doAuthedRequest(t, h.HandleCreate, "POST", "/v1/tasks", createBody, ownerID)
		var created model.Task
		json.NewDecoder(createRR.Body).Decode(&created)

		// Attacker tries to delete owner's task.
		req := httptest.NewRequest("DELETE", "/v1/tasks/"+created.ID, nil)
		req.SetPathValue("id", created.ID)
		rr := httptest.NewRecorder()
		withAuth(attackerID, h.HandleDelete)(rr, req)

		if rr.Code == http.StatusOK {
			t.Error("attacker should not be able to delete owner's task (BOLA)")
		}
	})
}

// =============================================================================
// OWASP API2:2023 (Broken Auth) — Auth endpoints use generic error messages
// Covers: RED-010, RED-011
// =============================================================================

func TestAPI2_BrokenAuth_GenericErrorMessages(t *testing.T) {
	database := testDB(t)
	h := &AuthHandler{DB: database, JWTSecret: testJWTSecret, RequireTLS: false}

	// Register a user first.
	regBody := model.EmailRegisterRequest{
		Email:    "auth_generic@test.com",
		Password: "Secure@Pass1",
	}
	doRequest(t, h.HandleEmailRegister, "POST", "/v1/auth/register", regBody)

	t.Run("LoginWrongPassword_GenericError", func(t *testing.T) {
		loginBody := model.EmailLoginRequest{
			Email:    "auth_generic@test.com",
			Password: "wrongpassword",
		}
		rr := doRequest(t, h.HandleEmailLogin, "POST", "/v1/auth/login", loginBody)
		errMsg := parseResponseError(t, rr)
		// Should say "invalid email or password", not "wrong password".
		if !strings.Contains(errMsg, "invalid email or password") {
			t.Errorf("expected generic error for wrong password, got: %q", errMsg)
		}
	})

	t.Run("LoginNonexistentEmail_GenericError", func(t *testing.T) {
		loginBody := model.EmailLoginRequest{
			Email:    "nonexistent@test.com",
			Password: "anypassword",
		}
		rr := doRequest(t, h.HandleEmailLogin, "POST", "/v1/auth/login", loginBody)
		errMsg := parseResponseError(t, rr)
		if !strings.Contains(errMsg, "invalid email or password") {
			t.Errorf("expected generic error for nonexistent email, got: %q", errMsg)
		}
	})

	t.Run("RegisterDuplicateEmail_GenericError", func(t *testing.T) {
		dupBody := model.EmailRegisterRequest{
			Email:    "auth_generic@test.com",
			Password: "anotherpassword",
		}
		rr := doRequest(t, h.HandleEmailRegister, "POST", "/v1/auth/register", dupBody)
		if rr.Code == http.StatusConflict {
			t.Error("409 Conflict reveals email existence")
		}
		errMsg := parseResponseError(t, rr)
		if strings.Contains(strings.ToLower(errMsg), "already registered") {
			t.Errorf("error message reveals email existence: %q", errMsg)
		}
	})
}

// =============================================================================
// OWASP API3:2023 (Broken Property Authorization) — User-writable text fields sanitized
// Covers: RED-005, RED-007, RED-014, RED-018
// =============================================================================

func TestAPI3_PropertyAuth_AllTextFieldsSanitized(t *testing.T) {
	database := testDB(t)

	xssPayloads := []string{
		"<script>alert(1)</script>",
		"<img src=x onerror=alert(1)>",
		"<svg/onload=alert(1)>",
		"<a href=javascript:alert(1)>click</a>",
	}

	t.Run("DisplayName", func(t *testing.T) {
		h := &AuthHandler{DB: database, JWTSecret: testJWTSecret, RequireTLS: false}
		for i, payload := range xssPayloads {
			email := "api3_dn_" + string(rune('a'+i)) + "@test.com"
			body := model.EmailRegisterRequest{
				Email:       email,
				Password:    "Secure@Pass1",
				DisplayName: payload,
			}
			rr := doRequest(t, h.HandleEmailRegister, "POST", "/v1/auth/register", body)
			if rr.Code != http.StatusCreated {
				t.Fatalf("registration failed for payload %q: %d (body: %s)", payload, rr.Code, rr.Body.String())
			}
			// Registration now returns verification_required, so check DB directly.
			user, err := db.GetUserByEmail(database, email)
			if err != nil {
				t.Fatalf("failed to get user after registration: %v", err)
			}
			if strings.Contains(user.DisplayName, "<") {
				t.Errorf("displayName not sanitized for %q: got %q", payload, user.DisplayName)
			}
		}
	})

	t.Run("TaskSubject", func(t *testing.T) {
		userID := createTestUser(t, database, "api3_ts@test.com", "API3", "hashedpass")
		h := &TaskHandler{DB: database}
		for _, payload := range xssPayloads {
			body := model.CreateTaskRequest{Subject: payload, Description: "clean"}
			rr := doAuthedRequest(t, h.HandleCreate, "POST", "/v1/tasks", body, userID)
			var task model.Task
			json.NewDecoder(rr.Body).Decode(&task)
			if strings.Contains(task.Subject, "<") {
				t.Errorf("task subject not sanitized for %q: got %q", payload, task.Subject)
			}
		}
	})

	t.Run("TaskDescription", func(t *testing.T) {
		userID := createTestUser(t, database, "api3_td@test.com", "API3D", "hashedpass")
		h := &TaskHandler{DB: database}
		for _, payload := range xssPayloads {
			body := model.CreateTaskRequest{Subject: "clean", Description: payload}
			rr := doAuthedRequest(t, h.HandleCreate, "POST", "/v1/tasks", body, userID)
			var task model.Task
			json.NewDecoder(rr.Body).Decode(&task)
			if strings.Contains(task.Description, "<") {
				t.Errorf("task description not sanitized for %q: got %q", payload, task.Description)
			}
		}
	})

	t.Run("PermissionModeValidation", func(t *testing.T) {
		invalid := []string{"root", "<script>", "autoApprove; rm -rf /"}
		for _, mode := range invalid {
			if validPermissionModes[mode] {
				t.Errorf("invalid permission mode %q accepted", mode)
			}
		}
	})

	t.Run("TaskStatusValidation", func(t *testing.T) {
		invalid := []string{"admin", "deleted", "DROP TABLE tasks", "<script>"}
		for _, status := range invalid {
			if validTaskStatuses[status] {
				t.Errorf("invalid task status %q accepted", status)
			}
		}
	})
}

// =============================================================================
// OWASP API4:2023 (Unrestricted Resource Consumption) — POST endpoints have MaxBytesReader + rate limits
// Covers: RED-008, RED-016, RED-017, RED-019
// =============================================================================

func TestAPI4_ResourceConsumption_OversizedBodiesRejected(t *testing.T) {
	database := testDB(t)
	userID := createTestUser(t, database, "api4@test.com", "API4", "hashedpass")
	deviceID := createTestDevice(t, database, userID, "API4Device")
	sessionID := "api4-session"
	createTestSession(t, database, sessionID, deviceID, userID)

	oversized := strings.Repeat("X", 2*1024*1024) // 2 MB

	// Test each handler that should have MaxBytesReader.
	type endpoint struct {
		name    string
		handler http.HandlerFunc
		body    string
		path    string
		pathVal map[string]string
	}
	endpoints := []endpoint{
		{
			"LiveActivityToken",
			HandleRegisterLiveActivityToken(ws.NewHub(), database),
			`{"pushToken":"` + oversized + `"}`,
			"/v2/sessions/" + sessionID + "/live-activity-token",
			map[string]string{"id": sessionID},
		},
		{
			"TaskCreate",
			(&TaskHandler{DB: database}).HandleCreate,
			`{"subject":"` + oversized + `"}`,
			"/v1/tasks",
			nil,
		},
		{
			"PushToStart",
			(&PushToStartHandler{DB: database}).HandleRegister,
			`{"token":"` + oversized + `"}`,
			"/v1/push-to-start-token",
			nil,
		},
		{
			"SubscriptionSync",
			(&SubscriptionHandler{DB: database, StoreKitKeySet: true}).HandleSync,
			`{"originalTransactionId":"` + oversized + `"}`,
			"/v1/subscription/sync",
			nil,
		},
	}

	for _, ep := range endpoints {
		t.Run(ep.name, func(t *testing.T) {
			req := httptest.NewRequest("POST", ep.path, strings.NewReader(ep.body))
			req.Header.Set("Content-Type", "application/json")
			for k, v := range ep.pathVal {
				req.SetPathValue(k, v)
			}
			rr := httptest.NewRecorder()
			withAuth(userID, ep.handler)(rr, req)

			// Should not return a success status (400 or 413 expected).
			if rr.Code == http.StatusOK || rr.Code == http.StatusCreated {
				t.Errorf("%s accepted oversized body (status %d)", ep.name, rr.Code)
			}
		})
	}
}

// =============================================================================
// OWASP API8:2023 (Security Misconfiguration) — Security headers + WS origin
// Covers: RED-006, RED-012
// (WS origin tests are in ws/origin_test.go; header tests in middleware/security_headers_test.go)
// This test verifies the middleware is wired into a handler chain.
// =============================================================================

func TestAPI8_SecurityMisc_SanitizeFunction(t *testing.T) {
	// Verify the sanitize functions exist and work correctly.
	t.Run("sanitizeText", func(t *testing.T) {
		cases := []struct {
			input  string
			expect string
		}{
			{"<script>alert(1)</script>", "scriptalert(1)/script"},
			{"Normal text", "Normal text"},
			{"Angle < bracket > test", "Angle  bracket  test"},
		}
		for _, tc := range cases {
			got := sanitizeText(tc.input)
			if got != tc.expect {
				t.Errorf("sanitizeText(%q) = %q, want %q", tc.input, got, tc.expect)
			}
		}
	})

	t.Run("sanitizeTaskText", func(t *testing.T) {
		input := "<b>Bold</b> and <i>italic</i>"
		got := sanitizeTaskText(input)
		if strings.Contains(got, "<") || strings.Contains(got, ">") {
			t.Errorf("sanitizeTaskText still contains angle brackets: %q", got)
		}
	})
}
