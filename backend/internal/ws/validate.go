package ws

import (
	"encoding/json"
	"errors"
	"fmt"
)

const maxEventPayloadSize = 64 * 1024 // 64 KB

// ValidateEventPayload performs lightweight validation on an incoming
// agent.session.event JSON payload. It checks:
//   - Total size does not exceed 64 KB
//   - sessionId is a non-empty string
//   - eventType is a non-empty string
//   - data is present and is a JSON object
//   - content, if present, is a JSON object
func ValidateEventPayload(data []byte) error {
	if len(data) > maxEventPayloadSize {
		return fmt.Errorf("event payload too large: %d bytes (max %d)", len(data), maxEventPayloadSize)
	}

	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return fmt.Errorf("event payload is not a valid JSON object: %w", err)
	}

	// sessionId: must exist and be a non-empty string.
	sidRaw, ok := raw["sessionId"]
	if !ok {
		return errors.New("missing required field: sessionId")
	}
	var sid string
	if err := json.Unmarshal(sidRaw, &sid); err != nil || sid == "" {
		return errors.New("sessionId must be a non-empty string")
	}

	// eventType: must exist and be a non-empty string.
	etRaw, ok := raw["eventType"]
	if !ok {
		return errors.New("missing required field: eventType")
	}
	var et string
	if err := json.Unmarshal(etRaw, &et); err != nil || et == "" {
		return errors.New("eventType must be a non-empty string")
	}

	// data: must exist and be a JSON object (starts with '{').
	dataRaw, ok := raw["data"]
	if !ok {
		return errors.New("missing required field: data")
	}
	if !isJSONObject(dataRaw) {
		return errors.New("data must be a JSON object")
	}

	// content: optional, but if present must be a JSON object.
	if contentRaw, ok := raw["content"]; ok {
		if !isJSONObject(contentRaw) {
			return errors.New("content must be a JSON object when present")
		}
	}

	return nil
}

// isJSONObject returns true if the raw JSON is a valid JSON object.
func isJSONObject(raw json.RawMessage) bool {
	var obj map[string]json.RawMessage
	return json.Unmarshal(raw, &obj) == nil
}
