package model

import "time"

type Project struct {
	ID        string    `json:"id"`
	UserID    string    `json:"userId"`
	Path      string    `json:"path"`
	Name      string    `json:"name"`
	Settings  string    `json:"settings,omitempty"`
	CreatedAt time.Time `json:"createdAt"`
	UpdatedAt time.Time `json:"updatedAt"`
}
