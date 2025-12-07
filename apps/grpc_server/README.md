# GrpcServer

gRPC server implementation for the Debrid Drive filesystem service.

This server exposes filesystem operations over gRPC using the centralized `stream_mount_api` protocol definitions.

## Features

- Full filesystem operations (create, read, write, delete, rename, move)
- Directory operations (mkdir, list)
- Hard link support
- File attribute management (chmod, truncate)
- Stream URL generation for torrent-backed files
- Comprehensive error handling with appropriate gRPC status codes

## Protocol Definitions

This server uses the centralized protocol definitions from:
- **Repository**: https://github.com/sushydev/stream_mount_api
- **Version**: v1.3.2

The protocol definitions are automatically included via the `stream_mount_api` package dependency.

## RPC Methods

### Filesystem Operations
- `Root()` - Get the root node of the filesystem
- `ReadDirAll(node_id)` - List all children of a directory
- `Lookup(node_id, name)` - Look up a child node by name

### File/Directory Creation
- `Create(parent_id, name, mode)` - Create a new file (returns created node)
- `Mkdir(parent_id, name)` - Create a new directory

### Modification Operations
- `Remove(parent_id, name)` - Remove a file or directory (recursive)
- `Rename(old_parent_id, old_name, new_parent_id, new_name)` - Rename/move a node
- `Link(node_id, parent_id, name)` - Create a hard link
- `Setattr(node_id, mode?, size?, atime?, mtime?, uid?, gid?)` - Set file attributes

### Data Operations
- `ReadFile(node_id, offset, size)` - Read file data
- `WriteFile(node_id, offset, data)` - Write file data
- `GetFileInfo(node_id)` - Get file metadata (size, mode, timestamps, ownership)
- `GetStreamUrl(node_id)` - Get streaming URL for torrent-backed files

## API Changes (v1.3.2)

### Breaking Changes
1. **CreateResponse now returns Node** - `Create()` now returns the created node in the response
2. **New Setattr RPC** - Added `Setattr()` for changing file attributes (chmod, truncate, touch, chown)
3. **Enhanced GetFileInfoResponse** - Now includes timestamps (atime, mtime, ctime), uid, gid, and nlink
4. **Enhanced Node message** - Node now includes size, timestamps, ownership, and hard link count

### Behavior Changes
- `Lookup()` returns `{:ok, %LookupResponse{node: nil}}` for non-existent nodes (was error)
- `ReadDirAll()` returns `{:ok, %ReadDirAllResponse{nodes: []}}` for non-existent directories (was error)
- `GetStreamUrl()` returns `{:ok, %GetStreamUrlResponse{url: nil}}` for non-existent nodes (was error)

These changes improve FUSE compatibility by following standard filesystem semantics.

## Testing

Run the test suite:

```bash
cd apps/grpc_server
mix test
```

Run only unit tests:
```bash
mix test test/unit/
```

Run E2E tests:
```bash
mix test test/e2e/
```

Exclude property-based tests:
```bash
mix test --exclude property
```

