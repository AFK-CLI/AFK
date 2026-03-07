package db

import (
	"database/sql"
	"fmt"
	"strings"
	"time"

	"github.com/AFK/afk-cloud/internal/auth"
	"github.com/AFK/afk-cloud/internal/model"
)

// CreateBetaRequest inserts a new beta request. Returns an error if the email already exists.
func CreateBetaRequest(d *sql.DB, req *model.BetaRequest) error {
	if req.ID == "" {
		req.ID = auth.GenerateID()
	}
	if req.CreatedAt == "" {
		req.CreatedAt = time.Now().UTC().Format(time.RFC3339)
	}
	if req.Status == "" {
		req.Status = "pending"
	}
	_, err := d.Exec(`
		INSERT INTO beta_requests (id, email, name, status, notes, created_at)
		VALUES (?, ?, ?, ?, ?, ?)
	`, req.ID, req.Email, req.Name, req.Status, req.Notes, req.CreatedAt)
	if err != nil {
		if strings.Contains(err.Error(), "UNIQUE constraint failed") {
			return fmt.Errorf("already registered")
		}
		return fmt.Errorf("insert beta request: %w", err)
	}
	return nil
}

// ListBetaRequests returns beta requests with optional status filter, newest first.
func ListBetaRequests(d *sql.DB, status string, limit, offset int) ([]model.BetaRequest, error) {
	query := `SELECT id, email, name, status, notes, created_at, COALESCE(invited_at, '') FROM beta_requests`
	var args []interface{}

	if status != "" {
		query += ` WHERE status = ?`
		args = append(args, status)
	}

	query += ` ORDER BY created_at DESC LIMIT ? OFFSET ?`
	args = append(args, limit, offset)

	rows, err := d.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("list beta requests: %w", err)
	}
	defer rows.Close()

	var results []model.BetaRequest
	for rows.Next() {
		var r model.BetaRequest
		if err := rows.Scan(&r.ID, &r.Email, &r.Name, &r.Status, &r.Notes, &r.CreatedAt, &r.InvitedAt); err != nil {
			return nil, fmt.Errorf("scan beta request: %w", err)
		}
		results = append(results, r)
	}
	return results, rows.Err()
}

// CountBetaRequests returns the total number of beta requests with optional status filter.
func CountBetaRequests(d *sql.DB, status string) (int, error) {
	query := `SELECT COUNT(*) FROM beta_requests`
	var args []interface{}
	if status != "" {
		query += ` WHERE status = ?`
		args = append(args, status)
	}

	var count int
	if err := d.QueryRow(query, args...).Scan(&count); err != nil {
		return 0, fmt.Errorf("count beta requests: %w", err)
	}
	return count, nil
}

// UpdateBetaRequestStatus updates the status and notes of a beta request.
func UpdateBetaRequestStatus(d *sql.DB, id, status, notes string) error {
	var invitedAt interface{}
	if status == "invited" {
		invitedAt = time.Now().UTC().Format(time.RFC3339)
	}

	result, err := d.Exec(`
		UPDATE beta_requests SET status = ?, notes = ?, invited_at = COALESCE(?, invited_at)
		WHERE id = ?
	`, status, notes, invitedAt, id)
	if err != nil {
		return fmt.Errorf("update beta request: %w", err)
	}

	n, _ := result.RowsAffected()
	if n == 0 {
		return fmt.Errorf("beta request not found")
	}
	return nil
}
