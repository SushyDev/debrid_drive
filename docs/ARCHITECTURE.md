# Architecture Overview

**Debrid Drive Ex Technical Architecture**

This document provides a deep technical dive into the architecture, design decisions, and implementation details of Debrid Drive Ex.

---

## Table of Contents

1. [System Overview](#system-overview)
2. [Core Components](#core-components)
3. [Data Flow](#data-flow)
4. [Database Schema](#database-schema)
5. [Concurrency & Performance](#concurrency--performance)
6. [Error Handling & Recovery](#error-handling--recovery)
7. [Design Decisions](#design-decisions)
8. [Future Improvements](#future-improvements)

---

## System Overview

### High-Level Architecture

```
┌────────────────────────── External Systems ──────────────────────────┐
│                                                                        │
│   RealDebrid API              Client Applications                     │
│   ┌──────────────┐           ┌──────────────┐                        │
│   │GET /torrents │           │ gRPC Clients │                        │
│   │DELETE /torrent│          │   (Go/etc)   │                        │
│   └──────┬───────┘           └──────┬───────┘                        │
│          │                           │                                │
└──────────┼───────────────────────────┼────────────────────────────────┘
           │                           │
           ↓                           ↓
┌──────────────────────────────────────────────────────────────────────┐
│                      Debrid Drive Ex                                  │
│ ┌────────────────────────────────────────────────────────────────┐  │
│ │                      Sync Engine App                            │  │
│ │  ┌──────────────────────────────────────────────────────────┐  │  │
│ │  │                    Service Layer                         │  │  │
│ │  │  ┌──────────┐  ┌─────────────┐  ┌────────────────────┐  │  │  │
│ │  │  │  Poller  │  │ TorrentSync │  │  TorrentVerifier   │  │  │  │
│ │  │  │          │→ │             │→ │                    │  │  │  │
│ │  │  │ Every 5m │  │ Add/Remove  │  │   Validate VFS     │  │  │  │
│ │  │  └────┬─────┘  └──────┬──────┘  └─────────────────┬──┘  │  │  │
│ │  │       │                │                           │      │  │  │
│ │  │       │ ┌──────────────┼───────────────────────────┘      │  │  │
│ │  │       │ │              │                                   │  │  │
│ │  │       ↓ ↓              ↓                                   │  │  │
│ │  │  ┌────────────────────────────────────────┐               │  │  │
│ │  │  │      RealDebridClient                  │               │  │  │
│ │  │  │   Rate Limited (50 req/min)            │               │  │  │
│ │  │  │   Token Bucket Algorithm               │               │  │  │
│ │  │  └────────────────┬───────────────────────┘               │  │  │
│ │  └──────────────────┼───────────────────────────────────────┘  │  │
│ │                     │                                           │  │
│ │  ┌──────────────────┼───────────────────────────────────────┐  │  │
│ │  │    Async Layer   ↓                                       │  │  │
│ │  │  ┌──────────────────────┐   ┌────────────────────────┐  │  │  │
│ │  │  │     JobQueue         │   │   DeletionWorker       │  │  │  │
│ │  │  │  Sequential Processing│→ │  API Delete + Cleanup  │  │  │  │
│ │  │  │  Retry Logic          │   │  Max 3 Attempts        │  │  │  │
│ │  │  └──────────────────────┘   └────────────────────────┘  │  │  │
│ │  └──────────────────────────────────────────────────────────┘  │  │
│ │                     ↓                                           │  │
│ │  ┌──────────────────────────────────────────────────────────┐  │  │
│ │  │              Database Layer (Ecto Schemas)               │  │  │
│ │  │  - Torrent                                               │  │  │
│ │  │  - TorrentFile                                           │  │  │
│ │  │  - RejectedTorrent                                       │  │  │
│ │  └──────────────────┬───────────────────────────────────────┘  │  │
│ └────────────────────┼───────────────────────────────────────────┘  │
│                      │                                               │
│ ┌────────────────────▼───────────────────────────────────────────┐  │
│ │                      VFS App                                    │  │
│ │  ┌──────────────────────────────────────────────────────────┐  │  │
│ │  │           VFS Context (Public API)                       │  │  │
│ │  │  - create_file/3, create_directory/3                    │  │  │
│ │  │  - create_hardlink/3, create_symlink/3                  │  │  │
│ │  │  - remove/2, remove_by_id/2, move/4                     │  │  │
│ │  │  - lookup/2, list_children/1, get_root/0                │  │  │
│ │  └────────────────────┬─────────────────────────────────────┘  │  │
│ │                       │                                         │  │
│ │  ┌────────────────────▼─────────────────────────────────────┐  │  │
│ │  │           Node Schema + Repo                             │  │  │
│ │  │  Self-referential tree (parent_id → id)                 │  │  │
│ │  └────────────────────┬─────────────────────────────────────┘  │  │
│ └───────────────────────┼──────────────────────────────────────────┘
│                         │                                            │
│ ┌───────────────────────▼──────────────────────────────────────────┐
│ │                   SQLite Database                                │
│ │  ┌──────────────────────────────────────────────────────────┐   │
│ │  │ Journal Mode: WAL (Write-Ahead Log)                      │   │
│ │  │ Pool Size: 1 (single writer, multiple readers)           │   │
│ │  │ Cache: 64MB (-64000 pages)                               │   │
│ │  │ Busy Timeout: 30 seconds                                 │   │
│ │  │                                                           │   │
│ │  │ Tables:                                                   │   │
│ │  │  - nodes (VFS tree structure)                            │   │
│ │  │  - torrents (RealDebrid metadata)                        │   │
│ │  │  - torrent_files (file details + links)                  │   │
│ │  │  - rejected_torrents (invalid torrents)                  │   │
│ │  └──────────────────────────────────────────────────────────┘   │
│ └──────────────────────────────────────────────────────────────────┘
│                         ↑                                            │
│ ┌───────────────────────┘─────────────────────────────────────────┐
│ │                   gRPC Server App                                │
│ │  ┌──────────────────────────────────────────────────────────┐   │
│ │  │         FileSystemService (Port 50051)                   │   │
│ │  │  14 RPC Methods:                                         │   │
│ │  │  - Root, ReadDirAll, Lookup                              │   │
│ │  │  - Create, Mkdir, Remove, Rename, Link                   │   │
│ │  │  - ReadLink, ReadFile, WriteFile                         │   │
│ │  │  - GetFileInfo, GetStreamUrl                             │   │
│ │  │                                                           │   │
│ │  │  Request Validation + Error Handling                     │   │
│ │  └──────────────────────────────────────────────────────────┘   │
│ └──────────────────────────────────────────────────────────────────┘
└────────────────────────────────────────────────────────────────────┘
```

---

## Core Components

### 1. VFS (Virtual Filesystem) Layer

**Location**: `apps/vfs/lib/vfs.ex`

**Purpose**: Provides filesystem semantics over SQLite

#### Key Features

- **Self-Referential Tree**: Uses `parent_id` foreign key for tree structure
- **Unix-Style Modes**: File type + permissions in single integer (e.g., `0o40755`)
- **Content Types**: Distinguishes files, directories, symlinks, hard links
- **Transactional**: All operations wrapped in Ecto transactions

#### Public API

```elixir
# Directory Operations
VFS.create_directory(parent_id, name, opts \\ [])
VFS.create_directory_recursive(parent_id, path)

# File Operations
VFS.create_file(parent_id, name, opts \\ [])
VFS.write_file(node_id, data, offset \\ 0)
VFS.read_file(node_id, offset \\ 0, size \\ nil)

# Link Operations
VFS.create_symlink(parent_id, name, target_path)
VFS.create_hardlink(parent_id, name, target_id)

# Navigation
VFS.lookup(parent_id, name)
VFS.list_children(parent_id)
VFS.get_root()
VFS.get_node(node_id)

# Modification
VFS.move(node_id, new_parent_id, new_name, opts \\ [])
VFS.remove(parent_id, name, opts \\ [])
VFS.remove_by_id(node_id, opts \\ [cascade: false])
```

#### File Mode System

```elixir
defmodule FileMode do
  # File Types
  @s_ifdir  0o040000  # Directory
  @s_ifreg  0o100000  # Regular file
  @s_iflnk  0o120000  # Symbolic link

  # Permissions
  @perm_755 0o755     # rwxr-xr-x
  @perm_644 0o644     # rw-r--r--

  # Combined
  def directory_mode, do: @s_ifdir ||| @perm_755  # 0o40755
  def file_mode, do: @s_ifreg ||| @perm_644      # 0o100644
end
```

#### Hard Link Design

- **Content Type**: `"inode/hardlink"`
- **Target Tracking**: `target_id` points to file node
- **Reference Counting**: Counted via SQL `COUNT(*)` queries
- **Deletion Rule**: Only delete file when last reference removed

---

### 2. Sync Engine Layer

**Location**: `apps/sync_engine`

**Purpose**: Synchronizes RealDebrid torrents with local VFS

#### 2.1 Poller Service

**Location**: `apps/sync_engine/lib/sync_engine/services/poller.ex`

**Responsibility**: Orchestrates periodic sync operations

```elixir
# Runs every 5 minutes
defmodule SyncEngine.Services.Poller do
  use GenServer

  @poll_interval 300_000  # 5 minutes

  def init(_) do
    schedule_poll()
    {:ok, %{}}
  end

  def handle_info(:poll, state) do
    client = SyncEngine.RealDebridClient.get_client()
    {:ok, root} = VFS.get_root()

    # Run sync
    TorrentSync.sync(client, torrents_root_id: root.id)

    # Run verification
    TorrentVerifier.verify_all()

    schedule_poll()
    {:noreply, state}
  end
end
```

#### 2.2 TorrentSync Service

**Location**: `apps/sync_engine/lib/sync_engine/services/torrent_sync.ex`

**Responsibility**: Add/remove torrents based on RealDebrid state

**Algorithm**:

```
1. Fetch torrents from RealDebrid API
   - Filter: status in ["downloaded", "seeding"]
   
2. Fetch torrents from local database
   - Build map: rd_id → torrent

3. Compare:
   - to_add = RealDebrid ∖ Local
   - to_remove = Local ∖ RealDebrid
   
4. Add new torrents:
   For each new torrent:
     a. Fetch detailed info (files + links)
     b. Validate (has selected files, link count matches)
     c. Create VFS directory: /media_manager/{torrent_id}/
     d. Create database record
     e. Create subdirectories (if file paths nested)
     f. Create file nodes with download links
     
5. Remove deleted torrents:
   For each removed torrent:
     a. Mark as "pending_deletion"
     b. Queue deletion job
     c. Sync will clean up after API confirms

6. Return statistics:
   {:ok, %{added: N, removed: M, skipped: K, errors: [...]}}
```

**Key Optimizations**:

- **API calls outside transactions**: Prevents timeout errors
- **Independent processing**: Failed torrent doesn't stop sync
- **Retry on next sync**: Failed additions automatically retried

#### 2.3 JobQueue (Custom Implementation)

**Location**: `apps/sync_engine/lib/sync_engine/job_queue.ex`

**Why Custom?** Replaced Oban due to:
- SQLite contention (Oban uses database for queue)
- Incompatible plugins (Pruner uses JOINs unsupported by SQLite)
- Wrong notifier (PostgreSQL-specific)

**Design**:

```elixir
defmodule SyncEngine.JobQueue do
  use GenServer

  defstruct [
    :queue,      # Erlang :queue of pending jobs
    :current,    # Currently processing job
    :failed      # List of failed jobs
  ]

  # Sequential Processing (one job at a time)
  def handle_cast({:enqueue, job}, state) do
    state = %{state | queue: :queue.in(job, state.queue)}
    
    # Start processing if idle
    if state.current == nil do
      process_next(state)
    end
  end

  # Retry Logic
  defp process_job(job) do
    case execute_job(job) do
      :ok ->
        Logger.info("Job completed: #{job.id}")
        
      {:error, reason} ->
        if job.attempts < 3 do
          # Exponential backoff: 5s, 10s, 20s
          delay = 5000 * :math.pow(2, job.attempts)
          Process.send_after(self(), {:retry, job}, delay)
        else
          Logger.error("Job failed permanently: #{job.id}")
          mark_failed(job)
        end
    end
  end
end
```

**Benefits**:

- **No database contention**: In-memory queue
- **Simple**: ~300 lines vs thousands in Oban
- **Fast recovery**: Reloads pending jobs from DB on startup
- **Rate-limited**: Uses existing RealDebridClient

---

### 3. gRPC Server Layer

**Location**: `apps/grpc_server/lib/grpc_server/file_system_service/server.ex`

**Purpose**: Exposes VFS via gRPC API

#### RPC Method Mapping

| RPC Method | VFS Function | Description |
|-----------|--------------|-------------|
| `Root` | `VFS.get_root()` | Get root node |
| `ReadDirAll` | `VFS.list_children()` | List directory contents |
| `Lookup` | `VFS.lookup()` | Find child by name |
| `Create` | `VFS.create_file()` | Create file |
| `Mkdir` | `VFS.create_directory()` | Create directory |
| `Remove` | `VFS.remove()` | Delete node |
| `Rename` | `VFS.move()` | Move/rename node |
| `Link` | `VFS.create_hardlink()` | Create hard link |
| `ReadLink` | `VFS.read_symlink()` | Read symlink target |
| `ReadFile` | `VFS.read_file()` | Read file data |
| `WriteFile` | `VFS.write_file()` | Write file data |
| `GetFileInfo` | `VFS.get_node()` | Get file metadata |
| `GetStreamUrl` | `fetch_download_url()` | Get RealDebrid link |

#### GetStreamUrl Implementation

**Flow**:

```
1. Lookup node_id in VFS
2. Check if node has associated torrent_file
3. If yes:
   a. Check if cached download_link is valid (< 24h)
   b. If valid, return cached link
   c. If expired, call RealDebrid unrestrict API
   d. Cache new link with timestamp
   e. Return link
4. If no torrent_file:
   - Return error :not_streamable
```

**Link Caching**:

```elixir
defmodule SyncEngine.Schemas.TorrentFile do
  schema "torrent_files" do
    field :link, :string             # Original RealDebrid link
    field :download_link, :string    # Cached direct download URL
    field :download_link_cached_at, :utc_datetime
    
    # Link expires after 24 hours
    def link_valid?(file) do
      if file.download_link && file.download_link_cached_at do
        age = DateTime.diff(DateTime.utc_now(), file.download_link_cached_at)
        age < 86_400  # 24 hours
      else
        false
      end
    end
  end
end
```

---

## Data Flow

### Sync Operation Flow

```
┌──────────────────────────────────────────────────────────────┐
│                    Sync Cycle (Every 5 min)                   │
└──────────────────────────────────────────────────────────────┘

1. Poller triggers sync
   │
   ├──> RealDebridClient.get_all_torrents()
   │    │
   │    └──> GET /torrents (RealDebrid API)
   │         Response: [{id, filename, status, ...}, ...]
   │
2. TorrentSync.sync()
   │
   ├──> Filter torrents (status in ["downloaded", "seeding"])
   │
   ├──> Fetch local torrents from database
   │
   ├──> Compare: find new/removed torrents
   │
   ├──> FOR EACH new torrent:
   │    │
   │    ├──> GET /torrents/info/{id} (detailed info)
   │    │    Response: {files: [...], links: [...]}
   │    │
   │    ├──> Validate torrent
   │    │    - Has selected files?
   │    │    - File count == Link count?
   │    │
   │    ├──> START TRANSACTION
   │    │    │
   │    │    ├──> VFS.create_directory(root_id, torrent_id)
   │    │    │    INSERT INTO nodes (parent_id, name, mode, ...)
   │    │    │
   │    │    ├──> INSERT INTO torrents (rd_id, filename, ...)
   │    │    │
   │    │    ├──> FOR EACH file:
   │    │    │    │
   │    │    │    ├──> Create subdirectories (if needed)
   │    │    │    │    INSERT INTO nodes ...
   │    │    │    │
   │    │    │    ├──> VFS.create_file(parent_id, filename)
   │    │    │    │    INSERT INTO nodes (content_type: "sync_engine/streamable")
   │    │    │    │
   │    │    │    └──> INSERT INTO torrent_files (rd_id, path, link, ...)
   │    │    │
   │    │    └──> COMMIT
   │    │
   │    └──> On error: ROLLBACK, mark as rejected
   │
   └──> FOR EACH removed torrent:
        │
        ├──> Mark torrent.deletion_status = "pending_deletion"
        │
        └──> JobQueue.enqueue({:delete_torrent, torrent_id})

3. JobQueue processes deletions
   │
   ├──> DELETE /torrents/delete/{id} (RealDebrid API)
   │
   ├──> On success:
   │    └──> Mark torrent.deletion_status = "deleted"
   │
   └──> On failure:
        └──> Retry up to 3 times with exponential backoff

4. Next sync cleans up deleted torrents
   │
   └──> FOR EACH torrent with deletion_status = "deleted":
        │
        ├──> VFS.remove_by_id(torrent.node_id, cascade: true)
        │    DELETE FROM nodes WHERE id = ... OR parent_id = ...
        │
        ├──> DELETE FROM torrent_files WHERE torrent_id = ...
        │
        └──> DELETE FROM torrents WHERE id = ...
```

### Stream URL Request Flow

```
Client Request: GetStreamUrl(node_id)
   │
   ├──> gRPC Server: FileSystemService.GetStreamUrl
   │    │
   │    ├──> VFS.get_node(node_id)
   │    │    SELECT * FROM nodes WHERE id = ?
   │    │
   │    ├──> Check content_type == "sync_engine/streamable"
   │    │
   │    ├──> SyncEngine.Torrents.get_torrent_file_by_node_id(node_id)
   │    │    SELECT * FROM torrent_files WHERE node_id = ?
   │    │
   │    ├──> Check if download_link is valid (< 24h)
   │    │
   │    ├──> If expired:
   │    │    │
   │    │    ├──> RealDebrid.Api.UnrestrictLink.unrestrict(client, link)
   │    │    │    POST /unrestrict/link {link: "..."}
   │    │    │    Response: {download: "https://...", ...}
   │    │    │
   │    │    └──> UPDATE torrent_files SET download_link = ?, cached_at = NOW()
   │    │
   │    └──> Return download_link

Client receives: {url: "https://..."}
```

---

## Database Schema

### SQLite Configuration

```elixir
config :vfs, VFS.Repo,
  database: "debrid_stream_dev.db",
  pool_size: 1,                     # Single writer
  log: false,                       # No query logs
  journal_mode: :wal,               # Write-Ahead Log
  busy_timeout: 30000,              # 30 second timeout
  cache_size: -64000,               # 64MB cache
  temp_store: :memory,              # In-memory temp tables
  synchronous: :normal,             # Balance durability/performance
  mmap_size: 30_000_000_000,        # 30GB memory-mapped I/O
  pragma_foreign_keys: false,       # Disabled for performance
  pragma_journal_size_limit: 64_000_000  # 64MB journal limit
```

### Schema Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                          nodes                              │
├─────────────────────────────────────────────────────────────┤
│ id (PK)                    INTEGER                          │
│ parent_id (FK → nodes.id)  INTEGER (nullable for root)      │
│ name                       TEXT                             │
│ mode                       INTEGER (file type + perms)      │
│ size                       INTEGER                          │
│ content_type               TEXT                             │
│ data                       BLOB (nullable)                  │
│ target_id (FK → nodes.id)  INTEGER (for hard links)        │
│ inserted_at                DATETIME                         │
│ updated_at                 DATETIME                         │
└─────────────────────────────────────────────────────────────┘
         ↑ 1:N                    1:1 ↓
         │                            │
┌────────┴──────────────┐   ┌─────────▼────────────────────────┐
│     torrents          │   │      torrent_files               │
├───────────────────────┤   ├──────────────────────────────────┤
│ id (PK)               │   │ id (PK)                          │
│ rd_id TEXT (unique)   │   │ rd_id TEXT                       │
│ filename              │   │ path TEXT                        │
│ hash                  │   │ bytes INTEGER                    │
│ bytes                 │   │ selected INTEGER                 │
│ host                  │   │ link TEXT                        │
│ progress              │   │ download_link TEXT               │
│ status                │   │ download_link_cached_at DATETIME │
│ deletion_status       │   │ torrent_id (FK → torrents.id)    │
│ deletion_attempts     │   │ node_id (FK → nodes.id)          │
│ node_id (FK→nodes.id) │   │ inserted_at                      │
│ inserted_at           │   │ updated_at                       │
│ updated_at            │   └──────────────────────────────────┘
└───────────────────────┘

┌──────────────────────────────────────────────────────────┐
│             rejected_torrents                            │
├──────────────────────────────────────────────────────────┤
│ id (PK)                                                  │
│ rd_id TEXT (unique)                                      │
│ filename TEXT                                            │
│ hash TEXT                                                │
│ reason TEXT                                              │
│ error_details TEXT                                       │
│ inserted_at                                              │
│ updated_at                                               │
└──────────────────────────────────────────────────────────┘
```

### Key Relationships

1. **nodes.parent_id → nodes.id**: Self-referential tree
2. **nodes.target_id → nodes.id**: Hard link target
3. **torrents.node_id → nodes.id**: Torrent directory
4. **torrent_files.node_id → nodes.id**: File node
5. **torrent_files.torrent_id → torrents.id**: File belongs to torrent

### Indexes

```sql
-- Efficient tree traversal
CREATE INDEX nodes_parent_id_index ON nodes(parent_id);

-- Efficient lookups
CREATE INDEX nodes_parent_id_name_index ON nodes(parent_id, name);

-- Hard link queries
CREATE INDEX nodes_target_id_index ON nodes(target_id);

-- Torrent lookups
CREATE UNIQUE INDEX torrents_rd_id_index ON torrents(rd_id);

-- File lookups
CREATE INDEX torrent_files_node_id_index ON torrent_files(node_id);
CREATE INDEX torrent_files_torrent_id_index ON torrent_files(torrent_id);
```

---

## Concurrency & Performance

### SQLite Concurrency Model

**WAL Mode Benefits**:
- **Multiple readers**: Concurrent SELECT queries
- **Single writer**: One INSERT/UPDATE/DELETE at a time
- **No blocking**: Readers don't block writers (and vice versa)

**Trade-offs**:
- **Pool size**: 1 (single connection)
- **Write serialization**: All writes queued
- **Busy timeout**: 30s (wait for lock)

### Rate Limiting

**Implementation**: Token bucket algorithm

```elixir
defmodule SyncEngine.RealDebridClient do
  use GenServer

  def init(_) do
    state = %{
      tokens: 50,
      max_tokens: 50,
      refill_rate: 50 / 60,  # 50 tokens per 60 seconds
      last_refill: System.monotonic_time(:second)
    }
    schedule_refill()
    {:ok, state}
  end

  def handle_call(:request, _from, state) do
    state = refill_tokens(state)
    
    if state.tokens >= 1 do
      state = %{state | tokens: state.tokens - 1}
      {:reply, :ok, state}
    else
      {:reply, {:error, :rate_limited}, state}
    end
  end

  defp refill_tokens(state) do
    now = System.monotonic_time(:second)
    elapsed = now - state.last_refill
    new_tokens = min(state.max_tokens, state.tokens + elapsed * state.refill_rate)
    %{state | tokens: new_tokens, last_refill: now}
  end
end
```

### Performance Optimizations

1. **API Calls Outside Transactions**
   - Fetch torrent info before starting DB transaction
   - Prevents 15s transaction timeouts
   - Allows parallel processing

2. **Independent Torrent Processing**
   - Each torrent addition is isolated
   - Failed torrent doesn't stop sync
   - Automatic retry on next cycle

3. **Efficient Tree Traversal**
   - Indexes on `parent_id` and `name`
   - Single query for directory listing
   - Recursive CTEs for deep deletion

4. **Link Caching**
   - Download links cached for 24h
   - Reduces unrestrict API calls
   - Lazy refresh (on-demand)

5. **Sequential Job Processing**
   - No database contention
   - Predictable performance
   - Simple error recovery

---

## Error Handling & Recovery

### Error Categories

#### 1. Transient Errors (Retry)
- Network timeouts
- API rate limits (429)
- Database busy (SQLITE_BUSY)
- Service unavailable (503)

**Strategy**: Exponential backoff retry

```elixir
defp retry_operation(fun, max_attempts \\ 3) do
  Enum.reduce_while(1..max_attempts, nil, fn attempt, _acc ->
    case fun.() do
      {:ok, result} -> {:halt, {:ok, result}}
      {:error, reason} when is_transient?(reason) ->
        if attempt < max_attempts do
          delay = :math.pow(2, attempt) * 1000
          Process.sleep(delay)
          {:cont, nil}
        else
          {:halt, {:error, {:max_retries, reason}}}
        end
    end
  end)
end
```

#### 2. Permanent Errors (Reject)
- Invalid torrent data
- Mismatched file/link counts
- No selected files
- Deleted from RealDebrid

**Strategy**: Mark as rejected, log, skip

```elixir
@rejection_errors [:file_link_mismatch, :invalid_torrent_data, :no_selected_files]

defp handle_error(rd_torrent, {:error, reason}) do
  if reason in @rejection_errors do
    SyncEngine.Torrents.reject_torrent(%{
      rd_id: rd_torrent.id,
      filename: rd_torrent.filename,
      reason: Atom.to_string(reason),
      error_details: "..."
    })
    Logger.warning("Rejected torrent #{rd_torrent.id}: #{reason}")
  else
    Logger.error("Transient error for #{rd_torrent.id}: #{reason}")
  end
end
```

#### 3. System Errors (Alert)
- Database corruption
- Disk full
- Out of memory
- Process crashes

**Strategy**: Supervisor restart, alert monitoring

### Recovery Mechanisms

1. **Job Queue Recovery**
   ```elixir
   # On startup, reload pending jobs
   def init(_) do
     pending = SyncEngine.Torrents.list_pending_deletions()
     queue = Enum.reduce(pending, :queue.new(), fn t, q ->
       :queue.in({:delete_torrent, t.id}, q)
     end)
     {:ok, %{queue: queue, current: nil, failed: []}}
   end
   ```

2. **Sync Idempotency**
   - Each sync compares current state
   - Re-adds failed torrents automatically
   - Cleans up deleted torrents

3. **Transaction Rollback**
   - Failed torrent addition rolls back
   - No partial VFS structures
   - Database stays consistent

---

## Design Decisions

### Why SQLite?

**Pros**:
- Embedded (no separate server)
- Zero configuration
- Single-file database
- Fast for read-heavy workloads
- ACID transactions

**Cons**:
- Single writer (serialized writes)
- Less suitable for high-concurrency writes
- Limited to single machine

**Decision**: Good fit for VFS use case (mostly reads, sequential writes)

### Why Custom JobQueue vs Oban?

**Oban Issues**:
- Requires database for queue (SQLite contention)
- Pruner plugin uses JOINs (unsupported by SQLite)
- PostgreSQL-specific notifier
- Overkill for simple deletion jobs

**Custom JobQueue Benefits**:
- In-memory queue (no DB contention)
- Simple implementation (~300 lines)
- Tailored to our needs (sequential, rate-limited)
- Fast recovery (reload from DB)

### Why gRPC?

**Benefits**:
- High performance (binary protocol)
- Strongly typed (Protobuf schemas)
- Streaming support (future use)
- Multi-language clients (Go, Python, etc.)

**Trade-offs**:
- More complex than REST
- Requires code generation
- Less debuggable than JSON

**Decision**: Performance and type safety outweigh complexity

### Why Umbrella App?

**Benefits**:
- Clear boundaries (VFS, gRPC, SyncEngine)
- Independent testing
- Shared dependencies (database)
- Gradual extraction (could become separate services)

**Trade-offs**:
- More boilerplate
- Compilation dependencies
- Shared application config

**Decision**: Maintainability and modularity justify overhead

---

## Future Improvements

### Performance

1. **Batch Operations**
   - Insert multiple files in single transaction
   - Reduce transaction overhead

2. **Parallel Sync**
   - Process torrents in parallel (with semaphore)
   - Faster initial sync

3. **Incremental Sync**
   - Only fetch changed torrents (if API supports)
   - Reduce API load

### Features

4. **Link Refresh Worker**
   - Proactively refresh expiring links
   - Better streaming experience

5. **Quota Management**
   - Track total storage usage
   - Enforce limits per user

6. **Webhook Integration**
   - Real-time updates from RealDebrid
   - Instant sync on changes

### Reliability

7. **Graceful Shutdown**
   - Finish current job before exit
   - Save pending jobs to database

8. **Circuit Breaker**
   - Stop calling API after repeated failures
   - Automatic recovery

9. **Health Metrics**
   - Prometheus/StatsD metrics
   - Grafana dashboards

### Operations

10. **Database Backups**
    - Automated SQLite backups
    - Point-in-time recovery

11. **Observability**
    - Structured logging (JSON)
    - Request tracing (OpenTelemetry)
    - Error tracking (Sentry)

---

## Conclusion

Debrid Drive Ex demonstrates a well-architected Elixir system with:
- **Clear separation of concerns** (VFS, Sync, gRPC)
- **Pragmatic technology choices** (SQLite, custom queue)
- **Production-ready patterns** (rate limiting, retry logic)
- **Extensible design** (umbrella app, modular services)

The system efficiently synchronizes thousands of torrents while maintaining filesystem semantics and providing a high-performance gRPC API.

---

**Last Updated**: December 6, 2025  
**Maintained By**: SushyDev
