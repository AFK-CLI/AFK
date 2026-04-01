package mcp

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Client calls the AFK REST API.
type Client struct {
	BaseURL    string
	AuthToken  string
	HTTPClient *http.Client
}

// NewClient creates an API client.
func NewClient(baseURL, authToken string) *Client {
	return &Client{
		BaseURL:   strings.TrimRight(baseURL, "/"),
		AuthToken: authToken,
		HTTPClient: &http.Client{
			Timeout: 30 * time.Second,
		},
	}
}

// Tools returns the MCP tool definitions.
func Tools() []ToolDef {
	return []ToolDef{
		// --- Core ---
		{
			Name:        "list_sessions",
			Description: "List AFK-monitored coding sessions. Returns session ID, project, status, provider, cost, and token usage.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"status": map[string]any{
						"type":        "string",
						"description": "Filter by status: running, idle, completed, error",
					},
					"limit": map[string]any{
						"type":        "integer",
						"description": "Max sessions to return (default 10)",
					},
				},
			},
		},
		{
			Name:        "get_session",
			Description: "Get details of a specific AFK session including recent events (tool calls, prompts, errors).",
			InputSchema: map[string]any{
				"type":     "object",
				"required": []string{"session_id"},
				"properties": map[string]any{
					"session_id": map[string]any{
						"type":        "string",
						"description": "Session UUID",
					},
					"limit": map[string]any{
						"type":        "integer",
						"description": "Max events to return (default 20)",
					},
				},
			},
		},
		{
			Name:        "list_devices",
			Description: "List enrolled AFK devices (macOS agents and iOS apps) with online status.",
			InputSchema: map[string]any{
				"type":       "object",
				"properties": map[string]any{},
			},
		},
		{
			Name:        "list_projects",
			Description: "List projects tracked by AFK with session counts.",
			InputSchema: map[string]any{
				"type":       "object",
				"properties": map[string]any{},
			},
		},
		// --- High value ---
		{
			Name:        "send_prompt",
			Description: "Send a prompt to a running AFK session. The prompt is forwarded to the Claude Code agent for execution. Returns immediately; results stream to the iOS app.",
			InputSchema: map[string]any{
				"type":     "object",
				"required": []string{"session_id", "prompt"},
				"properties": map[string]any{
					"session_id": map[string]any{
						"type":        "string",
						"description": "Session UUID to send the prompt to",
					},
					"prompt": map[string]any{
						"type":        "string",
						"description": "The prompt text to send",
					},
				},
			},
		},
		{
			Name:        "get_device_inventory",
			Description: "Get a device's installed Claude Code commands, skills, MCP servers, hooks, plans, and teams.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"device_id": map[string]any{
						"type":        "string",
						"description": "Device UUID. If omitted, returns inventory across all devices.",
					},
				},
			},
		},
		{
			Name:        "get_session_cost",
			Description: "Get cost and token usage breakdown for a session, or aggregated across all recent sessions.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"session_id": map[string]any{
						"type":        "string",
						"description": "Session UUID. If omitted, returns aggregate cost across recent sessions.",
					},
				},
			},
		},
		{
			Name:        "search_events",
			Description: "Search across session events by keyword. Finds errors, specific tool calls, prompts, etc.",
			InputSchema: map[string]any{
				"type":     "object",
				"required": []string{"query"},
				"properties": map[string]any{
					"query": map[string]any{
						"type":        "string",
						"description": "Search keyword (matches event type, tool name, or content)",
					},
					"session_id": map[string]any{
						"type":        "string",
						"description": "Limit search to a specific session (optional)",
					},
					"limit": map[string]any{
						"type":        "integer",
						"description": "Max results (default 20)",
					},
				},
			},
		},
		{
			Name:        "get_todos",
			Description: "Get the todo/task list synced from project todo.md files.",
			InputSchema: map[string]any{
				"type":       "object",
				"properties": map[string]any{},
			},
		},
		// --- Medium value ---
		{
			Name:        "stop_session",
			Description: "Send a stop signal to a running AFK session. The agent will attempt to interrupt the Claude Code process.",
			InputSchema: map[string]any{
				"type":     "object",
				"required": []string{"session_id"},
				"properties": map[string]any{
					"session_id": map[string]any{
						"type":        "string",
						"description": "Session UUID to stop",
					},
				},
			},
		},
		{
			Name:        "get_session_diff",
			Description: "Get a summary of files modified during a session (touched files from tool calls).",
			InputSchema: map[string]any{
				"type":     "object",
				"required": []string{"session_id"},
				"properties": map[string]any{
					"session_id": map[string]any{
						"type":        "string",
						"description": "Session UUID",
					},
				},
			},
		},
		{
			Name:        "list_permissions",
			Description: "List pending permission requests waiting for approval on the iOS app.",
			InputSchema: map[string]any{
				"type":       "object",
				"properties": map[string]any{},
			},
		},
	}
}

// Handler dispatches tool calls to the appropriate API endpoint.
func (c *Client) Handler(name string, rawArgs json.RawMessage) (string, error) {
	var args map[string]any
	if len(rawArgs) > 0 {
		if err := json.Unmarshal(rawArgs, &args); err != nil {
			return "", fmt.Errorf("invalid arguments: %w", err)
		}
	}
	if args == nil {
		args = map[string]any{}
	}

	switch name {
	case "list_sessions":
		return c.listSessions(args)
	case "get_session":
		return c.getSession(args)
	case "list_devices":
		return c.listDevices()
	case "list_projects":
		return c.listProjects()
	case "send_prompt":
		return c.sendPrompt(args)
	case "get_device_inventory":
		return c.getDeviceInventory(args)
	case "get_session_cost":
		return c.getSessionCost(args)
	case "search_events":
		return c.searchEvents(args)
	case "get_todos":
		return c.getTodos()
	case "stop_session":
		return c.stopSession(args)
	case "get_session_diff":
		return c.getSessionDiff(args)
	case "list_permissions":
		return c.listPermissions()
	default:
		return "", fmt.Errorf("unknown tool: %s", name)
	}
}

// --- Core tool implementations ---

func (c *Client) listSessions(args map[string]any) (string, error) {
	params := url.Values{}
	if status, ok := args["status"].(string); ok && status != "" {
		params.Set("status", status)
	}

	body, err := c.apiGet("/v1/sessions", params)
	if err != nil {
		return "", err
	}

	var sessions []map[string]any
	if err := json.Unmarshal(body, &sessions); err != nil {
		return "", fmt.Errorf("failed to parse sessions: %w", err)
	}

	limit := 10
	if l, ok := args["limit"].(float64); ok && l > 0 {
		limit = int(l)
	}
	if len(sessions) > limit {
		sessions = sessions[:limit]
	}

	return formatSessions(sessions), nil
}

func (c *Client) getSession(args map[string]any) (string, error) {
	sessionID, ok := args["session_id"].(string)
	if !ok || sessionID == "" {
		return "", fmt.Errorf("session_id is required")
	}

	limit := 20
	if l, ok := args["limit"].(float64); ok && l > 0 {
		limit = int(l)
	}

	params := url.Values{}
	params.Set("limit", fmt.Sprintf("%d", limit))

	body, err := c.apiGet(fmt.Sprintf("/v1/sessions/%s", sessionID), params)
	if err != nil {
		return "", err
	}

	var result map[string]any
	if err := json.Unmarshal(body, &result); err != nil {
		return "", fmt.Errorf("failed to parse session: %w", err)
	}

	return formatSessionDetail(result), nil
}

func (c *Client) listDevices() (string, error) {
	body, err := c.apiGet("/v1/devices", nil)
	if err != nil {
		return "", err
	}

	var devices []map[string]any
	if err := json.Unmarshal(body, &devices); err != nil {
		return "", fmt.Errorf("failed to parse devices: %w", err)
	}

	return formatDevices(devices), nil
}

func (c *Client) listProjects() (string, error) {
	body, err := c.apiGet("/v1/projects", nil)
	if err != nil {
		return "", err
	}

	var projects []map[string]any
	if err := json.Unmarshal(body, &projects); err != nil {
		return "", fmt.Errorf("failed to parse projects: %w", err)
	}

	return formatProjects(projects), nil
}

// --- High value tool implementations ---

func (c *Client) sendPrompt(args map[string]any) (string, error) {
	sessionID, ok := args["session_id"].(string)
	if !ok || sessionID == "" {
		return "", fmt.Errorf("session_id is required")
	}
	prompt, ok := args["prompt"].(string)
	if !ok || prompt == "" {
		return "", fmt.Errorf("prompt is required")
	}

	payload := map[string]any{
		"prompt": prompt,
	}

	body, err := c.apiPost(fmt.Sprintf("/v2/sessions/%s/continue", sessionID), payload)
	if err != nil {
		return "", fmt.Errorf("failed to send prompt: %w", err)
	}

	return fmt.Sprintf("Prompt sent to session %s. Response: %s", shortID(sessionID), string(body)), nil
}

func (c *Client) getDeviceInventory(args map[string]any) (string, error) {
	deviceID, _ := args["device_id"].(string)

	var body []byte
	var err error
	if deviceID != "" {
		body, err = c.apiGet(fmt.Sprintf("/v1/devices/%s/inventory", deviceID), nil)
	} else {
		body, err = c.apiGet("/v1/inventory", nil)
	}
	if err != nil {
		return "", err
	}

	var inventory map[string]any
	if err := json.Unmarshal(body, &inventory); err != nil {
		// Try as array (all-inventory returns array)
		var inventories []map[string]any
		if err2 := json.Unmarshal(body, &inventories); err2 != nil {
			return "", fmt.Errorf("failed to parse inventory: %w", err)
		}
		return formatInventories(inventories), nil
	}

	return formatInventory(inventory), nil
}

func (c *Client) getSessionCost(args map[string]any) (string, error) {
	sessionID, _ := args["session_id"].(string)

	if sessionID != "" {
		// Single session cost
		body, err := c.apiGet(fmt.Sprintf("/v1/sessions/%s", sessionID), nil)
		if err != nil {
			return "", err
		}
		var result map[string]any
		if err := json.Unmarshal(body, &result); err != nil {
			return "", fmt.Errorf("failed to parse session: %w", err)
		}
		return formatSessionCost(result), nil
	}

	// Aggregate cost across recent sessions
	body, err := c.apiGet("/v1/sessions", nil)
	if err != nil {
		return "", err
	}
	var sessions []map[string]any
	if err := json.Unmarshal(body, &sessions); err != nil {
		return "", fmt.Errorf("failed to parse sessions: %w", err)
	}
	return formatAggregateCost(sessions), nil
}

func (c *Client) searchEvents(args map[string]any) (string, error) {
	query, ok := args["query"].(string)
	if !ok || query == "" {
		return "", fmt.Errorf("query is required")
	}

	sessionID, _ := args["session_id"].(string)
	limit := 20
	if l, ok := args["limit"].(float64); ok && l > 0 {
		limit = int(l)
	}

	if sessionID != "" {
		// Search within a specific session
		params := url.Values{}
		params.Set("limit", "100") // fetch more to filter
		body, err := c.apiGet(fmt.Sprintf("/v1/sessions/%s", sessionID), params)
		if err != nil {
			return "", err
		}
		var result map[string]any
		if err := json.Unmarshal(body, &result); err != nil {
			return "", fmt.Errorf("failed to parse session: %w", err)
		}
		return filterEvents(result, query, limit), nil
	}

	// Search across recent sessions
	body, err := c.apiGet("/v1/sessions", nil)
	if err != nil {
		return "", err
	}
	var sessions []map[string]any
	if err := json.Unmarshal(body, &sessions); err != nil {
		return "", fmt.Errorf("failed to parse sessions: %w", err)
	}
	return searchAcrossSessions(c, sessions, query, limit), nil
}

func (c *Client) getTodos() (string, error) {
	body, err := c.apiGet("/v1/todos", nil)
	if err != nil {
		return "", err
	}

	var todos []map[string]any
	if err := json.Unmarshal(body, &todos); err != nil {
		return "", fmt.Errorf("failed to parse todos: %w", err)
	}

	return formatTodos(todos), nil
}

// --- Medium value tool implementations ---

func (c *Client) stopSession(args map[string]any) (string, error) {
	sessionID, ok := args["session_id"].(string)
	if !ok || sessionID == "" {
		return "", fmt.Errorf("session_id is required")
	}

	payload := map[string]any{
		"sessionId": sessionID,
	}

	_, err := c.apiPost(fmt.Sprintf("/v1/sessions/%s/stop", sessionID), payload)
	if err != nil {
		return "", fmt.Errorf("failed to stop session: %w", err)
	}

	return fmt.Sprintf("Stop signal sent to session %s.", shortID(sessionID)), nil
}

func (c *Client) getSessionDiff(args map[string]any) (string, error) {
	sessionID, ok := args["session_id"].(string)
	if !ok || sessionID == "" {
		return "", fmt.Errorf("session_id is required")
	}

	params := url.Values{}
	params.Set("limit", "200")
	body, err := c.apiGet(fmt.Sprintf("/v1/sessions/%s", sessionID), params)
	if err != nil {
		return "", err
	}

	var result map[string]any
	if err := json.Unmarshal(body, &result); err != nil {
		return "", fmt.Errorf("failed to parse session: %w", err)
	}

	return formatSessionDiff(result), nil
}

func (c *Client) listPermissions() (string, error) {
	// Permissions are real-time via WS, but we can check recent permission_needed events
	body, err := c.apiGet("/v1/sessions", url.Values{"status": []string{"running"}})
	if err != nil {
		return "", err
	}

	var sessions []map[string]any
	if err := json.Unmarshal(body, &sessions); err != nil {
		return "", fmt.Errorf("failed to parse sessions: %w", err)
	}

	return findPendingPermissions(c, sessions), nil
}

// --- HTTP helpers ---

func (c *Client) apiGet(path string, params url.Values) ([]byte, error) {
	u := c.BaseURL + path
	if params != nil && len(params) > 0 {
		u += "?" + params.Encode()
	}

	req, err := http.NewRequest("GET", u, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+c.AuthToken)

	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("API request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		respBody, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("API returned %d: %s", resp.StatusCode, string(respBody))
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	return body, nil
}

func (c *Client) apiPost(path string, payload any) ([]byte, error) {
	u := c.BaseURL + path

	data, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal payload: %w", err)
	}

	req, err := http.NewRequest("POST", u, bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+c.AuthToken)
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.HTTPClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("API request failed: %w", err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)

	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("API returned %d: %s", resp.StatusCode, string(body))
	}

	return body, nil
}

// --- Formatters ---

func formatSessions(sessions []map[string]any) string {
	if len(sessions) == 0 {
		return "No sessions found."
	}

	var b strings.Builder
	b.WriteString(fmt.Sprintf("Found %d session(s):\n\n", len(sessions)))

	for _, s := range sessions {
		id := str(s, "id")
		project := strAny(s, "projectPath", "project_path")
		status := str(s, "status")
		provider := str(s, "provider")
		description := str(s, "description")

		b.WriteString(fmt.Sprintf("- **%s** [%s] %s\n", shortID(id), status, provider))
		if project != "" {
			b.WriteString(fmt.Sprintf("  Project: %s\n", project))
		}
		if description != "" {
			b.WriteString(fmt.Sprintf("  Description: %s\n", description))
		}
		b.WriteString("\n")
	}
	return b.String()
}

func formatSessionDetail(result map[string]any) string {
	var b strings.Builder

	session, _ := result["session"].(map[string]any)
	if session == nil {
		session = result
	}

	id := str(session, "id")
	project := strAny(session, "projectPath", "project_path")
	status := str(session, "status")
	provider := str(session, "provider")
	branch := strAny(session, "gitBranch", "git_branch")

	b.WriteString(fmt.Sprintf("Session %s [%s]\n", shortID(id), status))
	b.WriteString(fmt.Sprintf("Provider: %s\n", provider))
	if project != "" {
		b.WriteString(fmt.Sprintf("Project: %s\n", project))
	}
	if branch != "" {
		b.WriteString(fmt.Sprintf("Branch: %s\n", branch))
	}

	events, _ := result["events"].([]any)
	if len(events) > 0 {
		b.WriteString(fmt.Sprintf("\nRecent events (%d):\n", len(events)))
		for _, e := range events {
			ev, ok := e.(map[string]any)
			if !ok {
				continue
			}
			evType := strAny(ev, "eventType", "event_type")
			ts := str(ev, "timestamp")
			b.WriteString(fmt.Sprintf("  [%s] %s\n", ts, evType))
		}
	}

	return b.String()
}

func formatDevices(devices []map[string]any) string {
	if len(devices) == 0 {
		return "No devices enrolled."
	}

	var b strings.Builder
	b.WriteString(fmt.Sprintf("Found %d device(s):\n\n", len(devices)))

	for _, d := range devices {
		name := str(d, "name")
		isOnline, _ := d["isOnline"].(bool)
		if !isOnline {
			isOnline, _ = d["is_online"].(bool)
		}
		lastSeen := strAny(d, "lastSeenAt", "last_seen_at")

		status := "offline"
		if isOnline {
			status = "online"
		}
		b.WriteString(fmt.Sprintf("- **%s** [%s] last seen: %s\n", name, status, lastSeen))
	}
	return b.String()
}

func formatProjects(projects []map[string]any) string {
	if len(projects) == 0 {
		return "No projects tracked."
	}

	var b strings.Builder
	b.WriteString(fmt.Sprintf("Found %d project(s):\n\n", len(projects)))

	for _, p := range projects {
		path := str(p, "path")
		name := str(p, "name")
		if name == "" {
			name = path
		}
		b.WriteString(fmt.Sprintf("- %s (%s)\n", name, path))
	}
	return b.String()
}

func formatInventory(inv map[string]any) string {
	var b strings.Builder
	b.WriteString("Device Inventory:\n\n")

	if cmds, ok := inv["globalCommands"].([]any); ok && len(cmds) > 0 {
		b.WriteString(fmt.Sprintf("Commands (%d): ", len(cmds)))
		names := make([]string, 0, len(cmds))
		for _, cmd := range cmds {
			if m, ok := cmd.(map[string]any); ok {
				names = append(names, str(m, "name"))
			}
		}
		b.WriteString(strings.Join(names, ", ") + "\n")
	}

	if skills, ok := inv["globalSkills"].([]any); ok && len(skills) > 0 {
		b.WriteString(fmt.Sprintf("Skills (%d): ", len(skills)))
		names := make([]string, 0, len(skills))
		for _, s := range skills {
			if m, ok := s.(map[string]any); ok {
				names = append(names, str(m, "name"))
			}
		}
		b.WriteString(strings.Join(names, ", ") + "\n")
	}

	if servers, ok := inv["mcpServers"].([]any); ok && len(servers) > 0 {
		b.WriteString(fmt.Sprintf("MCP Servers (%d): ", len(servers)))
		names := make([]string, 0, len(servers))
		for _, s := range servers {
			if m, ok := s.(map[string]any); ok {
				names = append(names, str(m, "name"))
			}
		}
		b.WriteString(strings.Join(names, ", ") + "\n")
	}

	if hooks, ok := inv["hooks"].([]any); ok && len(hooks) > 0 {
		b.WriteString(fmt.Sprintf("Hooks (%d): ", len(hooks)))
		names := make([]string, 0, len(hooks))
		for _, h := range hooks {
			if m, ok := h.(map[string]any); ok {
				names = append(names, str(m, "event"))
			}
		}
		b.WriteString(strings.Join(names, ", ") + "\n")
	}

	if plans, ok := inv["plans"].([]any); ok && len(plans) > 0 {
		b.WriteString(fmt.Sprintf("Plans: %d\n", len(plans)))
	}

	if teams, ok := inv["teams"].([]any); ok && len(teams) > 0 {
		b.WriteString(fmt.Sprintf("Teams: %d\n", len(teams)))
	}

	return b.String()
}

func formatInventories(inventories []map[string]any) string {
	if len(inventories) == 0 {
		return "No inventory data found."
	}
	var b strings.Builder
	for i, inv := range inventories {
		if i > 0 {
			b.WriteString("\n---\n\n")
		}
		deviceName := str(inv, "deviceName")
		if deviceName == "" {
			deviceName = str(inv, "device_name")
		}
		if deviceName != "" {
			b.WriteString(fmt.Sprintf("## %s\n\n", deviceName))
		}
		b.WriteString(formatInventory(inv))
	}
	return b.String()
}

func formatSessionCost(result map[string]any) string {
	session, _ := result["session"].(map[string]any)
	if session == nil {
		session = result
	}

	id := str(session, "id")
	tokensIn := numAny(session, "tokensIn", "tokens_in")
	tokensOut := numAny(session, "tokensOut", "tokens_out")
	costUsd := floatAny(session, "costUsd", "cost_usd")

	var b strings.Builder
	b.WriteString(fmt.Sprintf("Session %s cost breakdown:\n", shortID(id)))
	b.WriteString(fmt.Sprintf("  Input tokens:  %d\n", tokensIn))
	b.WriteString(fmt.Sprintf("  Output tokens: %d\n", tokensOut))
	b.WriteString(fmt.Sprintf("  Total tokens:  %d\n", tokensIn+tokensOut))
	b.WriteString(fmt.Sprintf("  Cost:          $%.4f\n", costUsd))
	return b.String()
}

func formatAggregateCost(sessions []map[string]any) string {
	var totalIn, totalOut int64
	var totalCost float64
	running := 0

	for _, s := range sessions {
		totalIn += numAny(s, "tokensIn", "tokens_in")
		totalOut += numAny(s, "tokensOut", "tokens_out")
		totalCost += floatAny(s, "costUsd", "cost_usd")
		if str(s, "status") == "running" || str(s, "status") == "idle" {
			running++
		}
	}

	var b strings.Builder
	b.WriteString(fmt.Sprintf("Aggregate cost across %d session(s):\n", len(sessions)))
	b.WriteString(fmt.Sprintf("  Active:        %d\n", running))
	b.WriteString(fmt.Sprintf("  Input tokens:  %d\n", totalIn))
	b.WriteString(fmt.Sprintf("  Output tokens: %d\n", totalOut))
	b.WriteString(fmt.Sprintf("  Total tokens:  %d\n", totalIn+totalOut))
	b.WriteString(fmt.Sprintf("  Total cost:    $%.4f\n", totalCost))
	return b.String()
}

func filterEvents(result map[string]any, query string, limit int) string {
	events, _ := result["events"].([]any)
	if len(events) == 0 {
		return "No events found."
	}

	q := strings.ToLower(query)
	var matches []string

	for _, e := range events {
		ev, ok := e.(map[string]any)
		if !ok {
			continue
		}
		// Search in event type, tool name, and payload values
		evJSON, _ := json.Marshal(ev)
		if strings.Contains(strings.ToLower(string(evJSON)), q) {
			evType := strAny(ev, "eventType", "event_type")
			ts := str(ev, "timestamp")
			matches = append(matches, fmt.Sprintf("[%s] %s", ts, evType))
			if len(matches) >= limit {
				break
			}
		}
	}

	if len(matches) == 0 {
		return fmt.Sprintf("No events matching '%s' found.", query)
	}

	var b strings.Builder
	b.WriteString(fmt.Sprintf("Found %d event(s) matching '%s':\n\n", len(matches), query))
	for _, m := range matches {
		b.WriteString(fmt.Sprintf("  %s\n", m))
	}
	return b.String()
}

func searchAcrossSessions(c *Client, sessions []map[string]any, query string, limit int) string {
	// Search the 5 most recent active sessions
	searchSessions := sessions
	if len(searchSessions) > 5 {
		searchSessions = searchSessions[:5]
	}

	var allMatches []string
	for _, s := range searchSessions {
		sid := str(s, "id")
		if sid == "" {
			continue
		}
		body, err := c.apiGet(fmt.Sprintf("/v1/sessions/%s", sid), url.Values{"limit": []string{"50"}})
		if err != nil {
			continue
		}
		var result map[string]any
		if err := json.Unmarshal(body, &result); err != nil {
			continue
		}
		events, _ := result["events"].([]any)
		q := strings.ToLower(query)
		for _, e := range events {
			ev, ok := e.(map[string]any)
			if !ok {
				continue
			}
			evJSON, _ := json.Marshal(ev)
			if strings.Contains(strings.ToLower(string(evJSON)), q) {
				evType := strAny(ev, "eventType", "event_type")
				ts := str(ev, "timestamp")
				allMatches = append(allMatches, fmt.Sprintf("[%s] %s in session %s", ts, evType, shortID(sid)))
				if len(allMatches) >= limit {
					break
				}
			}
		}
		if len(allMatches) >= limit {
			break
		}
	}

	if len(allMatches) == 0 {
		return fmt.Sprintf("No events matching '%s' found across recent sessions.", query)
	}

	var b strings.Builder
	b.WriteString(fmt.Sprintf("Found %d event(s) matching '%s':\n\n", len(allMatches), query))
	for _, m := range allMatches {
		b.WriteString(fmt.Sprintf("  %s\n", m))
	}
	return b.String()
}

func formatTodos(todos []map[string]any) string {
	if len(todos) == 0 {
		return "No todos found."
	}

	var b strings.Builder
	b.WriteString(fmt.Sprintf("Found %d todo list(s):\n\n", len(todos)))

	for _, t := range todos {
		project := strAny(t, "projectPath", "project_path")
		items, _ := t["items"].([]any)
		b.WriteString(fmt.Sprintf("**%s** (%d items):\n", project, len(items)))
		for _, item := range items {
			if m, ok := item.(map[string]any); ok {
				text := str(m, "text")
				checked, _ := m["checked"].(bool)
				mark := "[ ]"
				if checked {
					mark = "[x]"
				}
				b.WriteString(fmt.Sprintf("  %s %s\n", mark, text))
			}
		}
		b.WriteString("\n")
	}
	return b.String()
}

func formatSessionDiff(result map[string]any) string {
	events, _ := result["events"].([]any)
	if len(events) == 0 {
		return "No events found for this session."
	}

	files := make(map[string]string) // path -> last action
	for _, e := range events {
		ev, ok := e.(map[string]any)
		if !ok {
			continue
		}
		evType := strAny(ev, "eventType", "event_type")
		if evType != "tool_started" && evType != "tool_finished" {
			continue
		}
		payload, _ := ev["payload"].(map[string]any)
		if payload == nil {
			continue
		}
		toolName, _ := payload["toolName"].(string)
		if toolName != "Write" && toolName != "Edit" && toolName != "MultiEdit" {
			continue
		}
		// Extract file path from tool input
		content, _ := ev["content"].(map[string]any)
		if content == nil {
			continue
		}
		if summary, ok := content["toolInputSummary"].(string); ok {
			// Try to extract file path from summary
			for _, line := range strings.Split(summary, "\n") {
				line = strings.TrimSpace(line)
				if strings.HasPrefix(line, "file_path:") || strings.HasPrefix(line, "path:") {
					path := strings.TrimSpace(strings.SplitN(line, ":", 2)[1])
					files[path] = toolName
				}
			}
		}
	}

	if len(files) == 0 {
		return "No file modifications detected in this session."
	}

	var b strings.Builder
	b.WriteString(fmt.Sprintf("Files modified (%d):\n\n", len(files)))
	for path, action := range files {
		b.WriteString(fmt.Sprintf("  [%s] %s\n", action, path))
	}
	return b.String()
}

func findPendingPermissions(c *Client, sessions []map[string]any) string {
	if len(sessions) == 0 {
		return "No running sessions. No pending permissions."
	}

	var pending []string
	for _, s := range sessions {
		sid := str(s, "id")
		project := strAny(s, "projectPath", "project_path")
		status := str(s, "status")
		if status == "running" {
			body, err := c.apiGet(fmt.Sprintf("/v1/sessions/%s", sid), url.Values{"limit": []string{"5"}})
			if err != nil {
				continue
			}
			var result map[string]any
			if err := json.Unmarshal(body, &result); err != nil {
				continue
			}
			events, _ := result["events"].([]any)
			for _, e := range events {
				ev, ok := e.(map[string]any)
				if !ok {
					continue
				}
				evType := strAny(ev, "eventType", "event_type")
				if evType == "permission_needed" {
					payload, _ := ev["payload"].(map[string]any)
					toolName, _ := payload["toolName"].(string)
					pending = append(pending, fmt.Sprintf("- Session %s (%s): %s waiting for approval", shortID(sid), project, toolName))
				}
			}
		}
	}

	if len(pending) == 0 {
		return "No pending permission requests."
	}

	var b strings.Builder
	b.WriteString(fmt.Sprintf("Pending permissions (%d):\n\n", len(pending)))
	for _, p := range pending {
		b.WriteString(p + "\n")
	}
	return b.String()
}

// --- Helpers ---

func str(m map[string]any, key string) string {
	v, _ := m[key].(string)
	return v
}

func strAny(m map[string]any, keys ...string) string {
	for _, k := range keys {
		if v, _ := m[k].(string); v != "" {
			return v
		}
	}
	return ""
}

func numAny(m map[string]any, keys ...string) int64 {
	for _, k := range keys {
		switch v := m[k].(type) {
		case float64:
			return int64(v)
		case int64:
			return v
		case json.Number:
			n, _ := v.Int64()
			return n
		}
	}
	return 0
}

func floatAny(m map[string]any, keys ...string) float64 {
	for _, k := range keys {
		switch v := m[k].(type) {
		case float64:
			return v
		case json.Number:
			f, _ := v.Float64()
			return f
		}
	}
	return 0
}

func shortID(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}
