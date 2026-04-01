// AFK MCP Server — stdio-based MCP server for Claude Code integration.
//
// Claude Code connects to this binary via stdio transport to query
// AFK session and device data. Configure in ~/.claude/config.json:
//
//	{
//	  "mcpServers": {
//	    "afk": {
//	      "type": "stdio",
//	      "command": "/path/to/afk-mcp",
//	      "env": {
//	        "AFK_SERVER_URL": "https://your-server.example.com",
//	        "AFK_AUTH_TOKEN": "your-jwt-token"
//	      }
//	    }
//	  }
//	}
package main

import (
	"os"

	"github.com/AFK/afk-cloud/internal/mcp"
)

func main() {
	serverURL := os.Getenv("AFK_SERVER_URL")
	authToken := os.Getenv("AFK_AUTH_TOKEN")

	if serverURL == "" {
		mcp.LogToStderr("AFK_SERVER_URL is required")
		os.Exit(1)
	}
	if authToken == "" {
		mcp.LogToStderr("AFK_AUTH_TOKEN is required")
		os.Exit(1)
	}

	client := mcp.NewClient(serverURL, authToken)

	server := mcp.NewServer(mcp.Tools(), client.Handler)

	mcp.LogToStderr("AFK MCP server starting (API: %s)", serverURL)

	if err := server.Run(); err != nil {
		mcp.LogToStderr("server error: %v", err)
		os.Exit(1)
	}
}
