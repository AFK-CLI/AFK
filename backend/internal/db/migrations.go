package db

import (
	"database/sql"
	"fmt"
	"strings"
)

const migrationSQL = `
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    apple_user_id TEXT UNIQUE NOT NULL,
    email TEXT NOT NULL DEFAULT '',
    display_name TEXT NOT NULL DEFAULT '',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS devices (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    name TEXT NOT NULL,
    public_key TEXT NOT NULL,
    system_info TEXT NOT NULL DEFAULT '',
    enrolled_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_seen_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_online INTEGER NOT NULL DEFAULT 0,
    is_revoked INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS sessions (
    id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(id),
    user_id TEXT NOT NULL REFERENCES users(id),
    project_path TEXT NOT NULL DEFAULT '',
    git_branch TEXT NOT NULL DEFAULT '',
    cwd TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'running',
    started_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    tokens_in INTEGER NOT NULL DEFAULT 0,
    tokens_out INTEGER NOT NULL DEFAULT 0,
    turn_count INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS session_events (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES sessions(id),
    device_id TEXT NOT NULL,
    event_type TEXT NOT NULL,
    timestamp DATETIME NOT NULL,
    payload TEXT NOT NULL DEFAULT '{}',
    seq INTEGER NOT NULL DEFAULT 0,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS refresh_tokens (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    token_hash TEXT UNIQUE NOT NULL,
    expires_at DATETIME NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    revoked INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_devices_user_id ON devices(user_id);
CREATE INDEX IF NOT EXISTS idx_sessions_user_id ON sessions(user_id);
CREATE INDEX IF NOT EXISTS idx_sessions_device_id ON sessions(device_id);
CREATE INDEX IF NOT EXISTS idx_session_events_session_id ON session_events(session_id);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_token_hash ON refresh_tokens(token_hash);
`

const m2SecuritySQL = `
ALTER TABLE devices ADD COLUMN privacy_mode TEXT NOT NULL DEFAULT 'telemetry_only';

CREATE TABLE audit_log (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    device_id TEXT,
    action TEXT NOT NULL,
    details TEXT NOT NULL DEFAULT '{}',
    content_hash TEXT,
    ip_address TEXT,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_audit_log_user_id ON audit_log(user_id);
CREATE INDEX idx_audit_log_created_at ON audit_log(created_at);

CREATE TABLE project_privacy (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    device_id TEXT NOT NULL REFERENCES devices(id),
    project_path_hash TEXT NOT NULL,
    privacy_mode TEXT NOT NULL DEFAULT 'telemetry_only',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(device_id, project_path_hash)
);
`

const m2CommandsSQL = `
CREATE TABLE IF NOT EXISTS commands (
    id TEXT PRIMARY KEY,
    session_id TEXT NOT NULL REFERENCES sessions(id),
    user_id TEXT NOT NULL REFERENCES users(id),
    device_id TEXT NOT NULL REFERENCES devices(id),
    prompt_hash TEXT NOT NULL,
    prompt_encrypted TEXT,
    nonce TEXT UNIQUE NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at DATETIME NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_commands_session_id ON commands(session_id);
`

const m2EventContentSQL = `
ALTER TABLE session_events ADD COLUMN content TEXT;
`

const m2PushTokensSQL = `
CREATE TABLE IF NOT EXISTS push_tokens (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    device_token TEXT UNIQUE NOT NULL,
    platform TEXT NOT NULL DEFAULT 'ios',
    bundle_id TEXT NOT NULL DEFAULT '',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_push_tokens_user_id ON push_tokens(user_id);
`

const m2NotificationPrefsSQL = `
CREATE TABLE IF NOT EXISTS notification_preferences (
    user_id TEXT PRIMARY KEY REFERENCES users(id),
    permission_requests INTEGER NOT NULL DEFAULT 1,
    session_errors INTEGER NOT NULL DEFAULT 1,
    session_completions INTEGER NOT NULL DEFAULT 1,
    ask_user INTEGER NOT NULL DEFAULT 1,
    quiet_hours_start TEXT,
    quiet_hours_end TEXT,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
`

const m3ProjectsSQL = `
CREATE TABLE IF NOT EXISTS projects (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    path TEXT NOT NULL,
    name TEXT NOT NULL DEFAULT '',
    settings TEXT NOT NULL DEFAULT '{}',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_id, path)
);
CREATE INDEX IF NOT EXISTS idx_projects_user_id ON projects(user_id);

ALTER TABLE sessions ADD COLUMN project_id TEXT REFERENCES projects(id);
CREATE INDEX IF NOT EXISTS idx_sessions_project_id ON sessions(project_id);
`

const m3PushToStartTokensSQL = `
CREATE TABLE IF NOT EXISTS push_to_start_tokens (
    user_id TEXT PRIMARY KEY REFERENCES users(id),
    token TEXT NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
`

const m3DeviceKeysSQL = `
ALTER TABLE devices ADD COLUMN key_agreement_public_key TEXT;
ALTER TABLE devices ADD COLUMN key_version INTEGER NOT NULL DEFAULT 1;

CREATE TABLE IF NOT EXISTS device_keys (
    id TEXT PRIMARY KEY,
    device_id TEXT NOT NULL REFERENCES devices(id),
    key_type TEXT NOT NULL,
    public_key TEXT NOT NULL,
    version INTEGER NOT NULL DEFAULT 1,
    active INTEGER NOT NULL DEFAULT 1,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    revoked_at DATETIME
);
CREATE INDEX IF NOT EXISTS idx_device_keys_device_id ON device_keys(device_id);
`

// Make commands.session_id nullable (for new chat commands that don't have a session yet).
// SQLite doesn't support ALTER COLUMN, so we rebuild the table.
// PRAGMA foreign_keys must be OFF during table rebuild — handled in RunMigrations.
const m3CommandsNullableSessionSQL = `__NEEDS_FK_OFF__
CREATE TABLE IF NOT EXISTS commands_new (
    id TEXT PRIMARY KEY,
    session_id TEXT DEFAULT '',
    user_id TEXT NOT NULL REFERENCES users(id),
    device_id TEXT NOT NULL REFERENCES devices(id),
    prompt_hash TEXT NOT NULL,
    prompt_encrypted TEXT,
    nonce TEXT UNIQUE NOT NULL,
    status TEXT NOT NULL DEFAULT 'pending',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    expires_at DATETIME NOT NULL
);
INSERT INTO commands_new SELECT * FROM commands;
DROP TABLE commands;
ALTER TABLE commands_new RENAME TO commands;
CREATE INDEX IF NOT EXISTS idx_commands_session_id ON commands(session_id);
`

const m3SessionDescriptionSQL = `
ALTER TABLE sessions ADD COLUMN description TEXT NOT NULL DEFAULT '';
`

const m4SessionEphemeralKeySQL = `
ALTER TABLE sessions ADD COLUMN ephemeral_public_key TEXT;
`

const m4DeviceCapabilitiesSQL = `
ALTER TABLE devices ADD COLUMN capabilities TEXT NOT NULL DEFAULT '[]';
`

const m4EventDedupSQL = `
CREATE UNIQUE INDEX IF NOT EXISTS idx_session_events_dedup ON session_events(session_id, seq) WHERE seq > 0;
`

// Subscription support: add tier, expiry, product, and original transaction columns to users.
const m6SubscriptionSQL = `
ALTER TABLE users ADD COLUMN subscription_tier TEXT NOT NULL DEFAULT 'free';
ALTER TABLE users ADD COLUMN subscription_expires_at DATETIME;
ALTER TABLE users ADD COLUMN subscription_product_id TEXT;
ALTER TABLE users ADD COLUMN subscription_original_transaction_id TEXT;
CREATE INDEX idx_users_subscription_tier ON users(subscription_tier);
`

// Email/password auth: make apple_user_id nullable, add password_hash, add login_attempts table.
const m5EmailAuthSQL = `__NEEDS_FK_OFF__
CREATE TABLE users_new (
    id TEXT PRIMARY KEY,
    apple_user_id TEXT UNIQUE,
    email TEXT NOT NULL DEFAULT '',
    display_name TEXT NOT NULL DEFAULT '',
    password_hash TEXT,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO users_new SELECT id, apple_user_id, email, display_name, NULL, created_at, updated_at FROM users;
DROP TABLE users;
ALTER TABLE users_new RENAME TO users;

CREATE UNIQUE INDEX idx_users_email_password ON users(email) WHERE email != '' AND password_hash IS NOT NULL;

CREATE TABLE login_attempts (
    email TEXT NOT NULL,
    attempted_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    success INTEGER NOT NULL DEFAULT 0,
    ip_address TEXT
);
CREATE INDEX idx_login_attempts_email ON login_attempts(email, attempted_at);
`

const m7SessionActivityPrefSQL = `
ALTER TABLE notification_preferences ADD COLUMN session_activity INTEGER NOT NULL DEFAULT 0;
`

// Performance indexes for PurgeExpiredEvents and ListStuckSessions queries.
const m8PerformanceIndexesSQL = `
CREATE INDEX IF NOT EXISTS idx_session_events_created_at ON session_events(created_at);
CREATE INDEX IF NOT EXISTS idx_sessions_status_updated_at ON sessions(status, updated_at);
CREATE INDEX IF NOT EXISTS idx_commands_status_expires_at ON commands(status, expires_at);
`

const m9TasksSQL = `
CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    session_id TEXT REFERENCES sessions(id),
    project_id TEXT REFERENCES projects(id),
    source TEXT NOT NULL DEFAULT 'user',
    session_local_id TEXT,
    subject TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'pending',
    active_form TEXT NOT NULL DEFAULT '',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_tasks_user_id ON tasks(user_id);
CREATE INDEX IF NOT EXISTS idx_tasks_session_id ON tasks(session_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_tasks_claude_dedup ON tasks(session_id, session_local_id) WHERE source = 'claude_code';
`

const m10TodosSQL = `
CREATE TABLE IF NOT EXISTS todos (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    project_id TEXT NOT NULL DEFAULT '',
    project_path TEXT NOT NULL DEFAULT '',
    content_hash TEXT NOT NULL DEFAULT '',
    raw_content TEXT NOT NULL DEFAULT '',
    items_json TEXT NOT NULL DEFAULT '[]',
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_id, project_path)
);
CREATE INDEX IF NOT EXISTS idx_todos_user_id ON todos(user_id);
`

const m11SecurityHardeningSQL = `__NEEDS_FK_OFF__
CREATE TABLE IF NOT EXISTS refresh_tokens_new (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    token_hash TEXT UNIQUE NOT NULL,
    family_id TEXT NOT NULL DEFAULT '',
    expires_at DATETIME NOT NULL,
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    revoked INTEGER NOT NULL DEFAULT 0
);
INSERT INTO refresh_tokens_new (id, user_id, token_hash, family_id, expires_at, created_at, revoked)
    SELECT id, user_id, token_hash, id, expires_at, created_at, revoked FROM refresh_tokens;
DROP TABLE refresh_tokens;
ALTER TABLE refresh_tokens_new RENAME TO refresh_tokens;
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_token_hash ON refresh_tokens(token_hash);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_family_id ON refresh_tokens(family_id);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_expires_revoked ON refresh_tokens(expires_at, revoked);
CREATE INDEX IF NOT EXISTS idx_audit_log_created_at_purge ON audit_log(created_at);
`

const m12AppLogsSQL = `
CREATE TABLE IF NOT EXISTS app_logs (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    device_id TEXT NOT NULL DEFAULT '',
    source TEXT NOT NULL DEFAULT '',
    level TEXT NOT NULL DEFAULT 'info',
    subsystem TEXT NOT NULL DEFAULT '',
    message TEXT NOT NULL DEFAULT '',
    metadata TEXT NOT NULL DEFAULT '{}',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_app_logs_user_id ON app_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_app_logs_created_at ON app_logs(created_at);
CREATE INDEX IF NOT EXISTS idx_app_logs_user_level ON app_logs(user_id, level);
CREATE INDEX IF NOT EXISTS idx_app_logs_user_device ON app_logs(user_id, device_id);
`

const m12FeedbackSQL = `
CREATE TABLE IF NOT EXISTS feedback (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL REFERENCES users(id),
    device_id TEXT NOT NULL DEFAULT '',
    category TEXT NOT NULL DEFAULT 'general',
    message TEXT NOT NULL DEFAULT '',
    app_version TEXT NOT NULL DEFAULT '',
    platform TEXT NOT NULL DEFAULT '',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX IF NOT EXISTS idx_feedback_user_id ON feedback(user_id);
CREATE INDEX IF NOT EXISTS idx_feedback_created_at ON feedback(created_at);
`

const m13SessionCostSQL = `ALTER TABLE sessions ADD COLUMN cost_usd REAL NOT NULL DEFAULT 0;`

const m14BetaRequestsSQL = `
CREATE TABLE IF NOT EXISTS beta_requests (
    id TEXT PRIMARY KEY,
    email TEXT NOT NULL,
    name TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'pending',
    notes TEXT NOT NULL DEFAULT '',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    invited_at DATETIME
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_beta_requests_email ON beta_requests(email);
`

var migrations = []struct {
	Name string
	SQL  string
}{
	{Name: "001_init.up.sql", SQL: migrationSQL},
	{Name: "002_m2_security.up.sql", SQL: m2SecuritySQL},
	{Name: "003_m2_commands.up.sql", SQL: m2CommandsSQL},
	{Name: "004_m2_event_content.up.sql", SQL: m2EventContentSQL},
	{Name: "005_m2_push_tokens.up.sql", SQL: m2PushTokensSQL},
	{Name: "006_m2_notification_prefs.up.sql", SQL: m2NotificationPrefsSQL},
	{Name: "007_m3_projects.up.sql", SQL: m3ProjectsSQL},
	{Name: "008_m3_device_keys.up.sql", SQL: m3DeviceKeysSQL},
	{Name: "009_m3_push_to_start_tokens.up.sql", SQL: m3PushToStartTokensSQL},
	{Name: "010_m3_commands_nullable_session.up.sql", SQL: m3CommandsNullableSessionSQL},
	{Name: "011_session_description.up.sql", SQL: m3SessionDescriptionSQL},
	{Name: "012_m4_session_ephemeral_key.up.sql", SQL: m4SessionEphemeralKeySQL},
	{Name: "013_m4_device_capabilities.up.sql", SQL: m4DeviceCapabilitiesSQL},
	{Name: "014_m4_event_dedup.up.sql", SQL: m4EventDedupSQL},
	{Name: "015_m5_email_auth.up.sql", SQL: m5EmailAuthSQL},
	{Name: "016_l1_subscription.up.sql", SQL: m6SubscriptionSQL},
	{Name: "017_session_activity_pref.up.sql", SQL: m7SessionActivityPrefSQL},
	{Name: "018_performance_indexes.up.sql", SQL: m8PerformanceIndexesSQL},
	{Name: "019_tasks.up.sql", SQL: m9TasksSQL},
	{Name: "020_todos.up.sql", SQL: m10TodosSQL},
	{Name: "021_security_hardening.up.sql", SQL: m11SecurityHardeningSQL},
	{Name: "022_app_logs.up.sql", SQL: m12AppLogsSQL},
	{Name: "023_feedback.up.sql", SQL: m12FeedbackSQL},
	{Name: "024_session_cost.up.sql", SQL: m13SessionCostSQL},
	{Name: "025_beta_requests.up.sql", SQL: m14BetaRequestsSQL},
}

func RunMigrations(db *sql.DB) error {
	// Create migrations tracking table.
	_, err := db.Exec(`CREATE TABLE IF NOT EXISTS _migrations (
		name TEXT PRIMARY KEY,
		applied_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
	)`)
	if err != nil {
		return fmt.Errorf("create migrations table: %w", err)
	}

	for _, m := range migrations {
		// Check if already applied.
		var count int
		err := db.QueryRow("SELECT COUNT(*) FROM _migrations WHERE name = ?", m.Name).Scan(&count)
		if err != nil {
			return fmt.Errorf("check migration %s: %w", m.Name, err)
		}
		if count > 0 {
			continue
		}

		// Some migrations need FK enforcement off (e.g., table rebuilds).
		// PRAGMAs cannot run inside a transaction in SQLite, so handle them outside.
		sqlText := m.SQL
		needsFKOff := strings.HasPrefix(sqlText, "__NEEDS_FK_OFF__")
		if needsFKOff {
			sqlText = strings.TrimPrefix(sqlText, "__NEEDS_FK_OFF__")
			if _, err := db.Exec("PRAGMA foreign_keys = OFF"); err != nil {
				return fmt.Errorf("disable FK for migration %s: %w", m.Name, err)
			}
		}

		// Execute migration within a transaction for atomicity.
		tx, err := db.Begin()
		if err != nil {
			if needsFKOff {
				db.Exec("PRAGMA foreign_keys = ON")
			}
			return fmt.Errorf("begin transaction for migration %s: %w", m.Name, err)
		}

		if _, err := tx.Exec(sqlText); err != nil {
			tx.Rollback()
			if needsFKOff {
				db.Exec("PRAGMA foreign_keys = ON")
			}
			return fmt.Errorf("execute migration %s: %w", m.Name, err)
		}

		if _, err := tx.Exec("INSERT INTO _migrations (name) VALUES (?)", m.Name); err != nil {
			tx.Rollback()
			if needsFKOff {
				db.Exec("PRAGMA foreign_keys = ON")
			}
			return fmt.Errorf("record migration %s: %w", m.Name, err)
		}

		if err := tx.Commit(); err != nil {
			if needsFKOff {
				db.Exec("PRAGMA foreign_keys = ON")
			}
			return fmt.Errorf("commit migration %s: %w", m.Name, err)
		}

		if needsFKOff {
			if _, err := db.Exec("PRAGMA foreign_keys = ON"); err != nil {
				return fmt.Errorf("re-enable FK after migration %s: %w", m.Name, err)
			}
		}
	}

	return nil
}
