package ws

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/AFK/afk-cloud/internal/model"
)

func NewWSMessage(msgType string, payload interface{}) (*model.WSMessage, error) {
	data, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("marshal payload: %w", err)
	}
	return &model.WSMessage{
		Type:      msgType,
		Payload:   json.RawMessage(data),
		Timestamp: time.Now().UnixMilli(),
	}, nil
}

func ParseWSMessage(data []byte) (*model.WSMessage, error) {
	var msg model.WSMessage
	if err := json.Unmarshal(data, &msg); err != nil {
		return nil, fmt.Errorf("parse ws message: %w", err)
	}
	return &msg, nil
}
