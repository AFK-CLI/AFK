# Self-Hosting

AFK runs as a single Go binary behind nginx. The included `docker-compose.yml` sets up the backend, TLS termination, and automatic certificate renewal.

## Prerequisites

- A Linux server (or any host running Docker)
- Docker and Docker Compose v2
- A domain name with an A record pointing to your server
- An Apple Developer account (required for APNs push notifications)

## Server Setup

### 1. Clone and Configure

```bash
git clone https://github.com/AFK-CLI/AFK.git
cd AFK
cp backend/.env.example backend/.env
```

Edit `backend/.env`:

```env
# Required — generate with: openssl rand -hex 32
AFK_JWT_SECRET=your-random-32-byte-hex-string

# Optional — leave empty to auto-generate an ephemeral key pair on each restart.
# Set these for stable Ed25519 command signing across restarts.
# Generate with: go run backend/cmd/keygen/main.go  (or any Ed25519 keygen)
AFK_SERVER_PRIVATE_KEY=
AFK_SERVER_PUBLIC_KEY=

# Apple — see APNs Setup section below
AFK_APNS_KEY_ID=YOUR_KEY_ID
AFK_APNS_TEAM_ID=YOUR_TEAM_ID
AFK_APNS_BUNDLE_ID=com.your-org.afk
AFK_APPLE_BUNDLE_ID=com.your-org.afk,com.your-org.AFK-Agent
```

### 2. DNS

Create an A record pointing your domain to the server's IP:

```
afk.your-domain.com  →  203.0.113.10
```

### 3. nginx Configuration

Edit `nginx/afk.conf` and replace the `server_name` and SSL certificate paths with your domain:

```nginx
server_name afk.your-domain.com;
ssl_certificate /etc/nginx/certs/live/afk.your-domain.com/fullchain.pem;
ssl_certificate_key /etc/nginx/certs/live/afk.your-domain.com/privkey.pem;
```

The included config already handles WebSocket upgrades (`Upgrade` and `Connection` headers) and sets a 24-hour read timeout for persistent WebSocket connections.

### 4. TLS Certificates

Create the certificate and challenge directories:

```bash
mkdir -p certs certbot-www
```

Obtain the initial certificate:

```bash
# Start nginx temporarily without SSL for the ACME challenge
docker compose up -d nginx

docker compose run --rm certbot certonly \
  --webroot -w /var/www/certbot \
  -d afk.your-domain.com \
  --email you@example.com \
  --agree-tos --no-eff-email
```

The Certbot sidecar container renews certificates automatically every 12 hours. nginx reads the renewed certificates on the next connection.

### 5. Start Services

```bash
docker compose up -d
```

Verify:

```bash
curl https://afk.your-domain.com/healthz
```

Expected response:

```json
{
  "status": "ok",
  "version": "dev",
  "uptime": 42,
  "connections": {"agents": 0, "ios": 0},
  "db_size_bytes": 40960
}
```

## APNs Setup

Push notifications require an APNs authentication key from the Apple Developer portal.

### Generate the Key

1. Go to [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/authkeys/list) in the Apple Developer portal.
2. Under **Keys**, click **+**.
3. Enter a name (e.g., "AFK Push"), check **Apple Push Notifications service (APNs)**, and click **Continue** → **Register**.
4. Download the `.p8` file. You can only download it once.
5. Note the **Key ID** (10-character string) and your **Team ID** (from the top-right of the portal or Membership details).

### Configure

Place the key file:

```bash
mkdir -p secrets
cp ~/Downloads/AuthKey_XXXXXXXXXX.p8 secrets/apns-key.p8
```

Set the environment variables in `backend/.env`:

```env
AFK_APNS_KEY_PATH=/secrets/apns-key.p8
AFK_APNS_KEY_ID=XXXXXXXXXX
AFK_APNS_TEAM_ID=YOUR_TEAM_ID
AFK_APNS_BUNDLE_ID=com.your-org.afk
```

For App Store or TestFlight builds, set `AFK_APNS_PRODUCTION=1`. For Xcode debug builds, leave it empty (uses the APNs sandbox).

## Docker Compose Services

| Service | Image | Ports | Purpose |
|---------|-------|-------|---------|
| `afk-cloud` | Built from `backend/Dockerfile` | 9847 (internal only) | Go backend |
| `nginx` | `nginx:alpine` | 80, 443 | TLS termination, reverse proxy, WebSocket upgrade |
| `certbot` | `certbot/certbot` | — | Automatic Let's Encrypt renewal (12h loop) |

### Volumes

| Volume/Bind | Path in Container | Purpose |
|-------------|-------------------|---------|
| `afk-data` (named) | `/data` | SQLite database |
| `./secrets/apns-key.p8` | `/secrets/apns-key.p8` (ro) | APNs authentication key |
| `./certs` | `/etc/nginx/certs` (ro) | TLS certificates |
| `./certbot-www` | `/var/www/certbot` (ro) | ACME challenge directory |
| `./nginx/afk.conf` | `/etc/nginx/conf.d/default.conf` (ro) | nginx config |

## Configuration Reference

All environment variables are loaded from `backend/.env` (via godotenv) and can be overridden by actual environment variables.

### Required

| Variable | Type | Description |
|----------|------|-------------|
| `AFK_JWT_SECRET` | string (hex) | HMAC-SHA256 secret for JWT signing. Generate with `openssl rand -hex 32`. |

### Server

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `AFK_PORT` | int | `9847` | HTTP listen port. |
| `AFK_DB_PATH` | string | `afk.db` | SQLite database file path. Set to `/data/afk.db` in Docker. |
| `AFK_LOG_LEVEL` | string | `info` | Log level: `debug`, `info`, `warn`, `error`. |
| `AFK_LOG_FORMAT` | string | `json` | Log output format: `json` (default) or `text`. |
| `AFK_VERSION` | string | `""` | Version string. Injected via `-ldflags` at build time. |

### Signing

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `AFK_SERVER_PRIVATE_KEY` | string (hex) | `""` | Ed25519 private key for command signing. Auto-generated if empty (ephemeral — lost on restart). |
| `AFK_SERVER_PUBLIC_KEY` | string (hex) | `""` | Corresponding Ed25519 public key. Derived from private key if empty. |

### Apple / APNs

| Variable | Type | Default | Description |
|----------|------|---------|-------------|
| `AFK_APPLE_BUNDLE_ID` | string | `com.afk.app` | Comma-separated bundle IDs accepted for Apple identity token verification (e.g., `com.afk.app,com.afk.AFK-Agent`). |
| `AFK_APNS_KEY_PATH` | string | `""` | Path to the `.p8` APNs auth key. Push disabled if empty. |
| `AFK_APNS_KEY_ID` | string | `""` | APNs key ID (10-char string from Apple Developer portal). |
| `AFK_APNS_TEAM_ID` | string | `""` | Apple Developer Team ID. |
| `AFK_APNS_BUNDLE_ID` | string | `""` | Bundle ID for push notification topic. |
| `AFK_APNS_PRODUCTION` | string | `""` | Set to `"1"` for production APNs gateway. Empty uses sandbox. |

## First Run Walkthrough

1. Start services: `docker compose up -d`
2. Check health: `curl https://afk.your-domain.com/healthz`
3. On your Mac, build and run the agent. Set `AFK_SERVER_URL` in `config/AgentSecrets.xcconfig` to your server's URL.
4. Sign in on the agent using email/password or Apple Sign-In.
5. Build and run the iOS app. Set `AFK_SERVER_URL` in `config/Secrets.xcconfig`.
6. Sign in on iOS with the same account.
7. Start a Claude Code session in Terminal. The agent detects it and begins relaying events.
8. Open the iOS app — you should see the session appear in the list.

## Updating

```bash
cd AFK
git pull
docker compose build
docker compose up -d
```

The backend runs SQLite migrations automatically on startup. No manual migration step required.

## Backup

The SQLite database lives in the `afk-data` Docker volume, mapped to `/data/afk.db` inside the container.

To back up:

```bash
# Find the volume path
docker volume inspect afk_afk-data --format '{{ .Mountpoint }}'

# Copy the database (safe — SQLite WAL mode allows concurrent reads)
docker compose exec afk-cloud cp /data/afk.db /data/afk-backup.db
docker cp $(docker compose ps -q afk-cloud):/data/afk-backup.db ./afk-backup.db
```

**WAL considerations**: SQLite in WAL mode uses two additional files (`afk.db-wal` and `afk.db-shm`). If you copy the database file directly from the host filesystem, you must copy all three files atomically, or the backup may be inconsistent. The `cp` inside the container is safe because SQLite handles the WAL checkpoint internally. Alternatively, use `sqlite3 /data/afk.db ".backup /data/afk-backup.db"` for an atomic backup.

## Troubleshooting

### WebSocket connections fail

Check that nginx is proxying WebSocket upgrades. The config must include:

```nginx
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
proxy_read_timeout 86400s;
```

Verify with: `curl -i -N -H "Connection: Upgrade" -H "Upgrade: websocket" https://afk.your-domain.com/v1/ws/app`

### Push notifications not arriving

1. Verify the `.p8` key file exists at the configured path: `docker compose exec afk-cloud ls -la /secrets/apns-key.p8`
2. Check that `AFK_APNS_KEY_ID`, `AFK_APNS_TEAM_ID`, and `AFK_APNS_BUNDLE_ID` match your Apple Developer configuration.
3. For Xcode debug builds, `AFK_APNS_PRODUCTION` must be empty (uses sandbox). For TestFlight/App Store, set it to `"1"`.
4. Check backend logs for APNs errors: `docker compose logs afk-cloud | grep -i apns`
5. A 410 response from APNs means the device token is invalid — the app needs to re-register.

### Database locked errors

SQLite allows one writer at a time. This should not occur with a single backend instance. If you see lock errors:

1. Ensure only one `afk-cloud` container is running: `docker compose ps`
2. Check for zombie processes: `docker compose exec afk-cloud ps aux`
3. If the WAL file is very large, the backend may be under write pressure. Check disk I/O.

### Agent cannot connect

1. Verify the server URL is correct and reachable from the Mac: `curl https://afk.your-domain.com/healthz`
2. Check that the agent's `AFK_SERVER_URL` in `config/AgentSecrets.xcconfig` matches (include `https://`, no trailing slash).
3. Look at the agent's log output in Console.app (filter by process `AFK-Agent`).

### Certificate renewal fails

1. Ensure port 80 is open and nginx is serving the ACME challenge: `curl http://afk.your-domain.com/.well-known/acme-challenge/test`
2. Check Certbot logs: `docker compose logs certbot`
3. Manually trigger renewal: `docker compose run --rm certbot renew --dry-run`
