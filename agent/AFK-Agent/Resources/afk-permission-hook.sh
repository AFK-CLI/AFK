#!/bin/bash
# AFK Agent — Claude Code PermissionRequest hook
#
# This script is called by Claude Code when a tool requires user permission.
# It reads the permission request JSON from stdin, forwards it to the AFK Agent
# via a Unix domain socket, and waits for the agent to relay the iOS user's
# decision back. The decision JSON is printed to stdout for Claude Code to act on.
#
# If the agent is not running or the iOS user doesn't respond in time, the script
# exits with code 0 and empty stdout, causing Claude Code to fall back to the
# normal terminal permission prompt.

set -euo pipefail

INPUT=$(cat)
SOCKET="/tmp/afk-agent.sock"
TIMEOUT=120

# Check if the socket exists
if [ ! -S "$SOCKET" ]; then
    exit 0
fi

# Send the request to the agent and wait for response
# Use different tools depending on what's available
if command -v nc >/dev/null 2>&1; then
    RESPONSE=$(echo "$INPUT" | nc -U "$SOCKET" -w "$TIMEOUT" 2>/dev/null) || true
elif command -v socat >/dev/null 2>&1; then
    RESPONSE=$(echo "$INPUT" | socat -t "$TIMEOUT" - UNIX-CONNECT:"$SOCKET" 2>/dev/null) || true
else
    # No suitable tool available — fall through to terminal prompt
    exit 0
fi

if [ -z "${RESPONSE:-}" ]; then
    # Agent didn't respond or timed out — fall through to terminal prompt
    exit 0
fi

echo "$RESPONSE"
