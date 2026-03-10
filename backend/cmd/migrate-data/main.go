//go:build sqlite

package main

import (
	"database/sql"
	"flag"
	"fmt"
	"log"
	"strings"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
	_ "github.com/mattn/go-sqlite3"
)

// tables lists all tables in FK-safe insertion order.
var tables = []string{
	"users",
	"devices",
	"device_keys",
	"projects",
	"sessions",
	"session_events",
	"commands",
	"refresh_tokens",
	"audit_log",
	"project_privacy",
	"push_tokens",
	"push_to_start_tokens",
	"notification_preferences",
	"login_attempts",
	"email_verifications",
	"tasks",
	"todos",
	"app_logs",
	"feedback",
	"beta_requests",
	"passkey_credentials",
	"admin_users",
	"admin_passkey_credentials",
}

// boolColumns maps table.column to columns that are INTEGER in SQLite but BOOLEAN in PostgreSQL.
var boolColumns = map[string]bool{
	"devices.is_online":                              true,
	"devices.is_revoked":                             true,
	"device_keys.active":                             true,
	"refresh_tokens.revoked":                         true,
	"notification_preferences.permission_requests":   true,
	"notification_preferences.session_errors":        true,
	"notification_preferences.session_completions":   true,
	"notification_preferences.ask_user":              true,
	"notification_preferences.session_activity":      true,
	"login_attempts.success":                         true,
	"users.email_verified":                           true,
	"passkey_credentials.clone_warning":              true,
	"passkey_credentials.backup_eligible":            true,
	"passkey_credentials.backup_state":               true,
	"admin_users.totp_enabled":                       true,
	"admin_passkey_credentials.clone_warning":        true,
	"admin_passkey_credentials.backup_eligible":      true,
	"admin_passkey_credentials.backup_state":         true,
}

func main() {
	sqlitePath := flag.String("sqlite", "", "Path to SQLite database file")
	pgURL := flag.String("pg", "", "PostgreSQL connection URL")
	flag.Parse()

	if *sqlitePath == "" || *pgURL == "" {
		log.Fatal("Usage: migrate-data --sqlite /path/to/afk.db --pg postgres://user:pass@host:5432/dbname?sslmode=disable")
	}

	start := time.Now()

	// Open SQLite (source).
	srcDB, err := sql.Open("sqlite3", *sqlitePath+"?mode=ro")
	if err != nil {
		log.Fatalf("open sqlite: %v", err)
	}
	defer srcDB.Close()

	// Open PostgreSQL (target).
	dstDB, err := sql.Open("pgx", *pgURL)
	if err != nil {
		log.Fatalf("open postgres: %v", err)
	}
	defer dstDB.Close()

	if err := dstDB.Ping(); err != nil {
		log.Fatalf("ping postgres: %v", err)
	}

	var totalRows int64
	for _, table := range tables {
		n, err := migrateTable(srcDB, dstDB, table)
		if err != nil {
			log.Fatalf("migrate %s: %v", table, err)
		}
		totalRows += n
		if n > 0 {
			log.Printf("  %-35s %d rows", table, n)
		}
	}

	log.Printf("Migration complete: %d total rows in %s", totalRows, time.Since(start).Round(time.Millisecond))
}

func migrateTable(src, dst *sql.DB, table string) (int64, error) {
	// Check if table exists in source.
	var exists int
	err := src.QueryRow(fmt.Sprintf("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='%s'", table)).Scan(&exists)
	if err != nil || exists == 0 {
		return 0, nil
	}

	rows, err := src.Query(fmt.Sprintf("SELECT * FROM %s", table))
	if err != nil {
		return 0, fmt.Errorf("select: %w", err)
	}
	defer rows.Close()

	cols, err := rows.Columns()
	if err != nil {
		return 0, fmt.Errorf("columns: %w", err)
	}

	if len(cols) == 0 {
		return 0, nil
	}

	// Build INSERT ... ON CONFLICT DO NOTHING with positional params.
	placeholders := ""
	for i := range cols {
		if i > 0 {
			placeholders += ", "
		}
		placeholders += fmt.Sprintf("$%d", i+1)
	}
	colList := ""
	for i, c := range cols {
		if i > 0 {
			colList += ", "
		}
		colList += c
	}
	insertSQL := fmt.Sprintf("INSERT INTO %s (%s) VALUES (%s) ON CONFLICT DO NOTHING", table, colList, placeholders)

	// Identify which column indices are boolean.
	boolIdx := make(map[int]bool)
	for i, c := range cols {
		if boolColumns[table+"."+c] {
			boolIdx[i] = true
		}
	}

	tx, err := dst.Begin()
	if err != nil {
		return 0, fmt.Errorf("begin tx: %w", err)
	}

	stmt, err := tx.Prepare(insertSQL)
	if err != nil {
		tx.Rollback()
		return 0, fmt.Errorf("prepare: %w", err)
	}

	var count int64
	for rows.Next() {
		values := make([]interface{}, len(cols))
		ptrs := make([]interface{}, len(cols))
		for i := range values {
			ptrs[i] = &values[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			tx.Rollback()
			return 0, fmt.Errorf("scan row: %w", err)
		}

		// Convert types for PostgreSQL compatibility.
		for i := range values {
			if boolIdx[i] {
				switch v := values[i].(type) {
				case int64:
					values[i] = v != 0
				case int:
					values[i] = v != 0
				case float64:
					values[i] = v != 0
				}
			}
			// Strip null bytes — PostgreSQL rejects 0x00 in text columns.
			if s, ok := values[i].(string); ok {
				values[i] = strings.ReplaceAll(s, "\x00", "")
			}
		}

		if _, err := stmt.Exec(values...); err != nil {
			tx.Rollback()
			return 0, fmt.Errorf("insert row: %w", err)
		}
		count++
	}

	if err := rows.Err(); err != nil {
		tx.Rollback()
		return 0, fmt.Errorf("rows iteration: %w", err)
	}

	stmt.Close()
	if err := tx.Commit(); err != nil {
		return 0, fmt.Errorf("commit: %w", err)
	}

	return count, nil
}
