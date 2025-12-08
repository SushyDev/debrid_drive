# Configuration Guide

## Environment Variables

All sensitive configuration is now managed through environment variables. This keeps credentials secure and makes deployment easier.

### Required Variables

Create a `.env` file in the project root with the following:

```bash
# RealDebrid API Credentials (REQUIRED)
# Get your token from: https://real-debrid.com/apitoken
RD_API_TOKEN=your_api_token_here
# Get your webdav token from: https://real-debrid.com/account
RD_WEBDAV_PASSWORD=your_webdav_password_here
```

**Important**: 
- Use `.env.example` as a template
- In production, set these as system environment variables

### Optional Variables

```bash
# Logging Configuration (optional)
# Valid values: debug, info, warning, error
# Default: info (debug in dev environment)
LOG_LEVEL=info

# Database Configuration (optional)
# Defaults to: debrid_stream_#{env}.db
DATABASE_PATH=/path/to/database.db

# gRPC Server Port (optional)
# Default: 50051
GRPC_PORT=50051

# Sync Configuration (optional)
SYNC_POLL_INTERVAL=300000  # milliseconds (default: 5 minutes)
MAX_REQUESTS_PER_MINUTE=50  # API rate limit (default: 50)
```

## Logging

The application uses Elixir's built-in Logger with a unified configuration across all umbrella apps.

### Log Levels

Set the log level via the `LOG_LEVEL` environment variable:

- `debug` - Verbose logging for development and troubleshooting
- `info` - Standard operational logging (default)
- `warning` - Important warnings that need attention
- `error` - Error conditions only

### Log Format

Logs use the following format:
```
TIME METADATA[LEVEL] MESSAGE
```

Example:
```
23:45:12.456 pid=<0.234.0> application=sync_engine module=SyncEngine.Poller[info] Starting torrent sync
```

### Setting Log Level

```bash
# Development - use debug for verbose output
export LOG_LEVEL=debug

# Production - use info or warning
export LOG_LEVEL=info

# Troubleshooting - enable debug temporarily
LOG_LEVEL=debug iex -S mix
```

### Runtime Log Level Changes

In production releases, the log level is read from the environment at startup. To change it:

```bash
# Update environment variable
export LOG_LEVEL=debug

# Restart the application
```

Note: The log level cannot be changed at runtime without restarting the application.

### Per-Module Logging

The logger automatically includes the application and module name in metadata. This helps filter logs:

```bash
# Filter logs by application
LOG_LEVEL=debug iex -S mix | grep application=sync_engine

# Filter logs by module
LOG_LEVEL=debug iex -S mix | grep module=SyncEngine.Poller
```


## Loading Environment Variables

### Development

Use `direnv` (recommended) or load manually:

```bash
# With direnv (auto-loads .env)
direnv allow

# Or load manually
export $(cat .env | xargs)
iex -S mix
```

### Production

Set environment variables in your deployment system:

```bash
# Docker
docker run -e RD_API_TOKEN=xxx -e RD_WEBDAV_PASSWORD=yyy ...

# Systemd
Environment="RD_API_TOKEN=xxx"
Environment="RD_WEBDAV_PASSWORD=yyy"

# Kubernetes
env:
  - name: RD_API_TOKEN
    valueFrom:
      secretKeyRef:
        name: realdebrid-credentials
        key: api-token
```

## Health Check

The system includes a health check module for monitoring.

### Using the Health Check

```elixir
# In IEx
iex> SyncEngine.HealthCheck.check()
{:ok, %{
  status: :healthy,
  timestamp: ~U[2025-12-06 21:30:00.000000Z],
  checks: %{
    database: %{
      status: :ok,
      message: "Database operational",
      connected: true
    },
    job_queue: %{
      status: :ok,
      message: "Job queue operational",
      alive: true,
      pending_jobs: 5,
      failed_jobs: 0
    },
    config: %{
      status: :ok,
      message: "Configuration valid",
      rd_token_set: true,
      rd_password_set: true
    }
  }
}}

# Simple ping
iex> SyncEngine.HealthCheck.ping()
:ok
```

### Health Check Endpoint (Future)

To expose health check via HTTP/gRPC, add to your endpoint:

```elixir
# HTTP endpoint example
get "/health", do: 
  case SyncEngine.HealthCheck.check() do
    {:ok, result} -> json(conn, result)
    {:error, result} -> conn |> put_status(503) |> json(result)
  end
```

## Configuration Options

All options in `config/config.exs`:

### VFS Database
```elixir
config :vfs, VFS.Repo,
  database: "debrid_stream_#{config_env()}.db",
  pool_size: 1,
  log: false,  # Disable query logs
  journal_mode: :wal,  # Write-Ahead Logging
  busy_timeout: 30000,  # 30 second timeout
  cache_size: -64000,  # 64MB cache
```

### Sync Engine
```elixir
config :sync_engine,
  # RealDebrid API
  real_debrid_token: System.get_env("RD_API_TOKEN"),
  real_debrid_webdav_password: System.get_env("RD_WEBDAV_PASSWORD"),
  real_debrid_max_requests_per_minute: 50,
  
  # Torrent Sync
  torrents_container_name: "media_manager",
  torrent_directory_format: :filename,  # :id | :filename | :filename_with_id
  sync_limit: 100  # Max torrents per sync
```

## Verifying Configuration

After setting environment variables, verify:

```bash
# Check env vars are loaded
echo $RD_API_TOKEN
echo $RD_WEBDAV_PASSWORD

# Start IEx and check
iex -S mix

# Verify config
iex> Application.get_env(:sync_engine, :real_debrid_token)
"ZILASG6G2XOOOQCKKO3OUF6D2CIHOLZQIS5GYHYABIKJFQNB4BWA"

# Run health check
iex> SyncEngine.HealthCheck.check()
```

If health check shows errors:
- `config.status: :error` → Environment variables not set
- `database.status: :error` → Database connection issue
- `job_queue.status: :error` → JobQueue not running

## Security Best Practices

1. **Never commit credentials** to version control
2. **Rotate tokens regularly** on RealDebrid dashboard
3. **Use different tokens** for dev/staging/prod
4. **Monitor failed logins** on RealDebrid account
5. **Use secrets management** in production (Vault, AWS Secrets Manager, etc.)

## Troubleshooting

### "Configuration invalid" error

```bash
# Check if env vars are set
env | grep RD_

# Reload environment
export $(cat .env | xargs)
```

### Health check fails

```elixir
# Check each component
iex> SyncEngine.HealthCheck.check()

# Manual checks
iex> VFS.Repo.query("SELECT 1")
iex> Process.whereis(SyncEngine.JobQueue)
iex> Application.get_env(:sync_engine, :real_debrid_token)
```

### Database errors

```bash
# Reset database
rm *.db
mix ecto.create
mix ecto.migrate
```
