# Debrid Drive Ex

**A production-ready Elixir application that synchronizes RealDebrid torrents into a virtual filesystem accessible via gRPC.**

Debrid Drive creates a unified virtual filesystem from your RealDebrid torrents, exposing them through a gRPC API with full filesystem semantics (directories, files, hard links). Perfect for media servers, streaming applications, or any system needing filesystem access to RealDebrid content.

---

## Features

### Core Functionality
- 🗂️ **Virtual Filesystem (VFS)** - SQLite-backed filesystem with Unix semantics
- 🔄 **Automatic Sync** - Continuously syncs RealDebrid torrents into VFS
- 🔗 **Hard Links** - Create multiple references to files without duplication
- 🗑️ **Smart Deletion** - Async deletion with RealDebrid API integration
- 📡 **gRPC API** - High-performance interface for filesystem operations
- 🎬 **Streaming URLs** - Generate direct download links for media files

### Production Ready
- ✅ Environment-based configuration
- ✅ Unified logging with configurable levels
- ✅ Health check monitoring
- ✅ Rate limiting (50 req/min)
- ✅ Error recovery & retry logic
- ✅ SQLite WAL mode for concurrency
- ✅ Custom job queue (no external dependencies)

---

## Quick Start

### Prerequisites

- **RealDebrid Account** with API token

### Installation

```bash
# Clone the repository
git clone <your-repo-url>
cd debrid_drive_ex

# Install dependencies
mix deps.get

# Set up environment variables
cp .env.example .env
# Edit .env and add your RealDebrid credentials

# Create and migrate database
mix ecto.create
mix ecto.migrate

# Start the application
iex -S mix
```

### Environment Setup

Create a `.env` file in the project root:

```bash
# RealDebrid API Credentials (REQUIRED)
# Get your token from: https://real-debrid.com/apitoken
RD_API_TOKEN=your_api_token_here
RD_WEBDAV_PASSWORD=your_webdav_password_here

# Logging (OPTIONAL) - defaults to 'info'
# Valid values: debug, info, warning, error
LOG_LEVEL=info
```

**Load environment variables:**

```bash
# Option 1: Using direnv (recommended)
direnv allow

# Option 2: Manual export
export $(cat .env | xargs)
```

### Verify Installation

```elixir
# Start IEx
iex -S mix

# Check health status
iex> SyncEngine.HealthCheck.check()
{:ok, %{status: :healthy, ...}}

# View synchronized torrents
iex> DbInfo.stats()
```

---

## Architecture

Debrid Drive Ex is an **Elixir Umbrella application** with three isolated apps:

```
┌──────────────────────────────────────────────────────────┐
│                      SyncEngine                          │
│  ┌────────────┐  ┌──────────────┐  ┌────────────────┐  │
│  │   Poller   │  │  TorrentSync │  │   JobQueue     │  │
│  │ (5 min)    │→ │ (Add/Remove) │→ │   (Deletions)  │  │
│  └────────────┘  └──────────────┘  └────────────────┘  │
│         ↓               ↓                    ↓           │
│    RealDebrid API   VFS Layer       RealDebrid API      │
└──────────────────────────────────────────────────────────┘
                          ↓
         ┌────────────────────────────────────────┐
         │             VFS Layer                  │
         │  ┌──────────────────────────────────┐ │
         │  │   SQLite Database (WAL mode)     │ │
         │  │   - inodes (file metadata)        │ │
         │  │   - directory_entries (names)     │ │
         │  │   - torrents (metadata)           │ │
         │  │   - torrent_files (with links)    │ │
         │  └──────────────────────────────────┘ │
         └────────────────────────────────────────┘
                          ↓
         ┌────────────────────────────────────────┐
         │           gRPC Server                  │
         │  FileSystemService (14 RPC methods)    │
         │  - Root, ReadDirAll, Lookup            │
         │  - Create, Mkdir, Remove, Rename       │
         │  - Link, ReadLink, ReadFile, WriteFile │
         │  - GetFileInfo, GetStreamUrl           │
         └────────────────────────────────────────┘
                          ↓
                  Client Applications
```

### Key Components

#### 1. **VFS (Virtual Filesystem)** - `apps/vfs`
- SQLite-backed POSIX-compliant filesystem with inode system
- Unix-style file modes (directories, files, symlinks, hard links)
- Separates inodes (metadata) from directory entries (names)
- Full CRUD operations with transactional guarantees
- Optimized with WAL mode, 64MB cache, 30s busy timeout

#### 2. **gRPC Server** - `apps/grpc_server`
- Protobuf-based API (port 50051)
- 14 RPC methods for filesystem operations
- Integrates with SyncEngine for streaming URLs
- Request validation and error handling

#### 3. **Sync Engine** - `apps/sync_engine`
- **Poller**: Fetches torrents every 5 minutes
- **TorrentSync**: Adds/removes torrents, creates VFS structure
- **JobQueue**: Async deletion processing with retries
- **TorrentVerifier**: Validates VFS integrity
- **RealDebridClient**: Rate-limited API client (50 req/min)

---

## Usage

### IEx Helper Commands

The project includes convenient database inspection tools in `.iex.exs`:

```elixir
# Complete database overview
DbInfo.overview()

# Quick stats
DbInfo.stats()
# => 97 torrents, 111 files, 2.02 TB

# List torrents (with optional limit)
DbInfo.torrents()
DbInfo.torrents(limit: 10)

# View job queue
DbInfo.queue()

# Show rejected torrents
DbInfo.rejected()

# Display VFS tree
DbInfo.tree()
DbInfo.tree(max_depth: 3)

# Show logging configuration
DbInfo.log_info()

# Demo logging at all levels
DbInfo.demo_logging()
```

### Health Monitoring

```elixir
# Full health check
SyncEngine.HealthCheck.check()
# => {:ok, %{status: :healthy, checks: %{...}}}

# Simple ping
SyncEngine.HealthCheck.ping()
# => :ok
```

### Manual Sync Operations

```elixir
# Trigger manual sync
client = SyncEngine.RealDebridClient.get_client()
{:ok, root} = VFS.get_root()
SyncEngine.Services.TorrentSync.sync(client, torrents_root_id: root.id)

# View job queue status
SyncEngine.JobQueue.status()
```

### Logging

Debrid Drive uses Elixir's built-in Logger with a unified configuration. Control verbosity with the `LOG_LEVEL` environment variable:

```bash
# Set log level (debug, info, warning, error)
export LOG_LEVEL=debug

# Start with specific log level
LOG_LEVEL=debug iex -S mix

# Or in IEx, check current level
DbInfo.log_info()
DbInfo.demo_logging()
```

**Log Levels:**
- `debug` - Verbose output for development and troubleshooting
- `info` - Standard operational logging (default)
- `warning` - Important warnings that need attention
- `error` - Error conditions only

See [Configuration Guide](CONFIGURATION.md#logging) for more details.

---

## Configuration

All configuration is in `config/config.exs`. Key settings:

### Database (VFS)
```elixir
config :vfs, VFS.Repo,
  database: "debrid_stream_#{config_env()}.db",
  pool_size: 1,
  log: false,
  journal_mode: :wal,
  busy_timeout: 30000,
  cache_size: -64000  # 64MB
```

### Sync Engine
```elixir
config :sync_engine,
  # Loaded from environment variables
  real_debrid_token: System.get_env("RD_API_TOKEN"),
  real_debrid_webdav_password: System.get_env("RD_WEBDAV_PASSWORD"),
  
  # Rate limiting
  real_debrid_max_requests_per_minute: 50,
  
  # Sync configuration
  torrents_container_name: "media_manager",
  torrent_directory_format: :filename,
  sync_limit: 100
```

See [Configuration Guide](CONFIGURATION.md) for complete details.

---

## How It Works

### Torrent Synchronization

1. **Polling** (every 5 minutes)
   - Fetches all "downloaded" torrents from RealDebrid API
   - Filters by status: only `downloaded` and `seeding`

2. **Comparison**
   - Compares RealDebrid torrents with local database
   - Identifies new torrents to add, deleted torrents to remove

3. **Addition** (for new torrents)
   - Fetches detailed torrent info (files, links)
   - Creates VFS directory: `/media_manager/{torrent_id}/`
   - Creates file nodes for each selected file
   - Stores download links with 24-hour validity

4. **Deletion** (for removed torrents)
   - Marks torrent for deletion in database
   - JobQueue processes deletion asynchronously
   - Calls RealDebrid delete API
   - Next sync cleans up VFS nodes

### Virtual Filesystem Structure

```
/ (root)
└── media_manager/
    ├── abc123torrent/           # Torrent directory
    │   ├── Movie.mkv            # Streamable file
    │   ├── Subtitles/
    │   │   └── English.srt
    │   └── Sample/
    │       └── sample.mkv
    ├── def456torrent/
    │   └── TVShow.S01E01.mkv
    └── favorites/               # User-created directory
        └── Movie.mkv            # Hard link to abc123torrent/Movie.mkv
```

### Job Queue (Async Deletions)

- **Sequential processing**: One job at a time (no SQLite contention)
- **Rate limited**: Respects API limits (50 req/min)
- **Retry logic**: Exponential backoff (5s → 10s → 20s)
- **Max attempts**: 3 retries before marking as failed
- **Recovery**: Reloads pending jobs on restart

### Efficiency Features

1. **API Call Optimization**
   - Moved API calls outside database transactions
   - Prevents timeout errors (15s limit)
   - Parallel-safe sync processing

2. **Database Optimization**
   - SQLite WAL mode (concurrent reads)
   - 64MB cache size
   - 30s busy timeout
   - No SQL query logs (production-ready)

3. **Rate Limiting**
   - Conservative 50 req/min (leaves headroom)
   - Token bucket algorithm
   - Graceful backoff on limits

4. **Error Recovery**
   - Independent torrent processing
   - Failed torrents don't stop sync
   - Automatic retry on next sync cycle

---

## Testing

```bash
# Run all tests
mix test

# Run specific app tests
cd apps/vfs && mix test
cd apps/grpc_server && mix test
cd apps/sync_engine && mix test

# Run with coverage
mix test --cover
```

---

## Troubleshooting

### Common Issues

#### 1. "Configuration invalid" error

```bash
# Check environment variables
env | grep RD_

# Reload .env
export $(cat .env | xargs)
```

#### 2. Database errors

```bash
# Reset database
rm *.db
mix ecto.create
mix ecto.migrate
```

#### 3. gRPC connection refused

```bash
# Check if server is running
lsof -i :50051

# Check logs
tail -f log/dev.log
```

#### 4. Sync not working

```elixir
# Check health
SyncEngine.HealthCheck.check()

# Manual sync
client = SyncEngine.RealDebridClient.get_client()
{:ok, root} = VFS.get_root()
SyncEngine.Services.TorrentSync.sync(client, torrents_root_id: root.id)
```

See [Configuration Guide](CONFIGURATION.md) for more troubleshooting.

---

## Documentation

- **[Architecture Overview](ARCHITECTURE.md)** - Technical deep dive
- **[Configuration Guide](CONFIGURATION.md)** - Setup and config

---

## Development

### Project Structure

```
debrid_drive_ex/
├── apps/
│   ├── vfs/                 # Virtual filesystem
│   ├── grpc_server/         # gRPC API
│   └── sync_engine/         # RealDebrid sync
├── config/                  # Configuration files
├── docs/                    # Documentation
├── .env                     # Local credentials (gitignored)
├── .env.example             # Template
└── mix.exs                  # Umbrella project
```

### Code Style

- Follow Elixir standard formatting: `mix format`
- Document public functions with `@doc`
- Add typespecs for public APIs

### Contributing

1. Fork the repository
2. Create a feature branch
3. Write tests first (TDD)
4. Implement the feature
5. Run `mix format` and `mix test`
6. Submit a pull request

---

## License

[LICENSE.md](LICENSE.md)

---

## Acknowledgments

- Built with [Elixir](https://elixir-lang.org/)
- gRPC via [grpc-elixir](https://github.com/elixir-grpc/grpc)
- Database with [Ecto](https://github.com/elixir-ecto/ecto) and [Exqlite](https://github.com/elixir-sqlite/exqlite)
- RealDebrid API integration

---

## Support

- **Issues**: [GitHub Issues](https://github.com/SushyDev/debrid_drive/issues)
