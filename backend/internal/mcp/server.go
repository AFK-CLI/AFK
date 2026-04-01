// Package mcp implements a minimal MCP (Model Context Protocol) server
// using JSON-RPC 2.0 over stdio. Claude Code connects to this server
// to query AFK session/device data.
package mcp

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
)

// Request is a JSON-RPC 2.0 request.
type Request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      any             `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

// Response is a JSON-RPC 2.0 response.
type Response struct {
	JSONRPC string `json:"jsonrpc"`
	ID      any    `json:"id"`
	Result  any    `json:"result,omitempty"`
	Error   *Error `json:"error,omitempty"`
}

// Error is a JSON-RPC 2.0 error.
type Error struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// Notification is a JSON-RPC 2.0 notification (no ID, no response expected).
type Notification struct {
	JSONRPC string `json:"jsonrpc"`
	Method  string `json:"method"`
	Params  any    `json:"params,omitempty"`
}

// ToolDef describes a tool for tools/list.
type ToolDef struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	InputSchema any    `json:"inputSchema"`
}

// TextContent is an MCP text content block.
type TextContent struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

// Server handles the JSON-RPC 2.0 stdio loop.
type Server struct {
	tools   []ToolDef
	handler func(name string, args json.RawMessage) (string, error)
}

// NewServer creates a new MCP server with the given tools and handler.
func NewServer(tools []ToolDef, handler func(name string, args json.RawMessage) (string, error)) *Server {
	return &Server{tools: tools, handler: handler}
}

// Run starts the stdio JSON-RPC loop. Blocks until stdin is closed.
func (s *Server) Run() error {
	scanner := bufio.NewScanner(os.Stdin)
	// MCP messages can be large (session events, etc.)
	scanner.Buffer(make([]byte, 0, 1024*1024), 4*1024*1024)

	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}

		var req Request
		if err := json.Unmarshal(line, &req); err != nil {
			s.writeError(nil, -32700, "parse error")
			continue
		}

		// Notifications (no ID) don't get a response
		if req.ID == nil {
			s.handleNotification(req.Method, req.Params)
			continue
		}

		resp := s.handleRequest(&req)
		s.writeJSON(resp)
	}

	return scanner.Err()
}

func (s *Server) handleNotification(method string, params json.RawMessage) {
	// MCP notifications we can safely ignore:
	// notifications/initialized, notifications/cancelled, etc.
}

func (s *Server) handleRequest(req *Request) *Response {
	switch req.Method {
	case "initialize":
		return s.handleInitialize(req)
	case "tools/list":
		return s.handleToolsList(req)
	case "tools/call":
		return s.handleToolsCall(req)
	case "ping":
		return &Response{JSONRPC: "2.0", ID: req.ID, Result: map[string]any{}}
	default:
		return &Response{
			JSONRPC: "2.0",
			ID:      req.ID,
			Error:   &Error{Code: -32601, Message: fmt.Sprintf("method not found: %s", req.Method)},
		}
	}
}

func (s *Server) handleInitialize(req *Request) *Response {
	return &Response{
		JSONRPC: "2.0",
		ID:      req.ID,
		Result: map[string]any{
			"protocolVersion": "2024-11-05",
			"serverInfo": map[string]any{
				"name":    "afk",
				"version": "1.0.0",
			},
			"capabilities": map[string]any{
				"tools": map[string]any{},
			},
		},
	}
}

func (s *Server) handleToolsList(req *Request) *Response {
	return &Response{
		JSONRPC: "2.0",
		ID:      req.ID,
		Result: map[string]any{
			"tools": s.tools,
		},
	}
}

func (s *Server) handleToolsCall(req *Request) *Response {
	var params struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if err := json.Unmarshal(req.Params, &params); err != nil {
		return &Response{
			JSONRPC: "2.0",
			ID:      req.ID,
			Error:   &Error{Code: -32602, Message: "invalid params"},
		}
	}

	text, err := s.handler(params.Name, params.Arguments)
	if err != nil {
		return &Response{
			JSONRPC: "2.0",
			ID:      req.ID,
			Result: map[string]any{
				"content": []TextContent{{Type: "text", Text: err.Error()}},
				"isError": true,
			},
		}
	}

	return &Response{
		JSONRPC: "2.0",
		ID:      req.ID,
		Result: map[string]any{
			"content": []TextContent{{Type: "text", Text: text}},
		},
	}
}

func (s *Server) writeJSON(v any) {
	data, err := json.Marshal(v)
	if err != nil {
		return
	}
	fmt.Fprintf(os.Stdout, "%s\n", data)
}

func (s *Server) writeError(id any, code int, message string) {
	s.writeJSON(&Response{
		JSONRPC: "2.0",
		ID:      id,
		Error:   &Error{Code: code, Message: message},
	})
}

// LogToStderr writes a message to stderr (visible in Claude Code's MCP debug log).
func LogToStderr(format string, args ...any) {
	fmt.Fprintf(io.Discard, format, args...) // suppress for now
	fmt.Fprintf(os.Stderr, format+"\n", args...)
}
