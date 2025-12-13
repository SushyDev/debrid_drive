# VFS - Virtual Filesystem Context

A comprehensive virtual filesystem (VFS) implementation for managing files, directories, and hardlinks with support for streaming torrent files via Real Debrid.

## Overview

The VFS module provides a clean abstraction for managing a virtual filesystem with the following features:

- **Hierarchical file system**: Create and manage directories and files with parent-child relationships
- **Hardlinks**: Support for both POSIX hardlinks and virtual inode hardlinks (pointing to torrent files)
- **Streaming support**: Detect which hardlinks are streamable (have Real Debrid download links)
- **Efficient batch operations**: Preload data for multiple nodes with a single database query
- **SQLite backend**: Uses Ecto with SQLite for persistence

## Core Concepts

### Nodes
A `VFS.Node` represents either a file or directory in the virtual filesystem. Each node has:
- `name`: The filename or directory name
- `parent_id`: Reference to parent node (nil for root)
- `mode`: Unix-style permissions
- `is_hardlink`: Boolean flag indicating if this is a hardlink
- `data`: Storage for hardlink target information

### Hardlinks

#### POSIX Hardlinks
Traditional hardlinks that point to another file in the VFS:
```elixir
{:ok, target} = VFS.create_file(parent_id, "original.txt", size: 100)
{:ok, link} = VFS.create_hardlink(parent_id, "link.txt", target.id)
```

#### Virtual Inode Hardlinks
Hardlinks that point to torrent files (virtual inodes) from Real Debrid:
```elixir
{:ok, hardlink} = VFS.create_hardlink_to_virtual_inode(
  parent_id,
  "movie.mkv",
  torrent_file_id,
  size: 1_000_000
)
```

Virtual inode hardlinks are encoded with `data: "vi:#{torrent_file_id}"` to distinguish them from POSIX hardlinks.

## Streaming Files

### Detecting Streamability

A hardlink is **streamable** if and only if:
1. It is a hardlink to a virtual inode (torrent file)
2. The target virtual inode has a download link from Real Debrid

Use `VFS.Streamability` to check streamability:

```elixir
alias VFS.Streamability

# Check if a node is streamable
node = VFS.get_node(node_id)
if Streamability.streamable?(node) do
  # This hardlink can be streamed
end
```

### Efficient Streamability Checking

For single nodes, `streamable?/1` automatically falls back to querying the database:
```elixir
node = VFS.get_node(node_id)
# Queries database if needed (1 query)
is_streamable = Streamability.streamable?(node)
```

For multiple nodes, **preload** the virtual inodes to avoid N+1 queries:
```elixir
nodes = VFS.list_children(parent_id)
  |> Streamability.preload_for_streamability()  # 1 query for all virtual inodes

# Now checking is_streamable? is free (no additional queries)
Enum.each(nodes, fn node ->
  if Streamability.streamable?(node) do
    # Can stream this file
  end
end)
```

### Performance Characteristics

| Scenario | Queries | Performance |
|----------|---------|-------------|
| Single hardlink (not preloaded) | 1 | Falls back to single query |
| Single regular file | 0 | No query needed |
| Batch of hardlinks (preloaded) | 1 | Single JOIN query for all |
| Batch of mixed nodes (preloaded) | 1 | All in one query |

## API Quick Reference

### File and Directory Operations
- `VFS.get_root/0` - Get or create the root directory
- `VFS.get_node(id)` - Retrieve a node by ID
- `VFS.create_directory(parent_id, name, opts)` - Create a directory
- `VFS.create_file(parent_id, name, opts)` - Create a file
- `VFS.list_children(parent_id)` - List children of a node
- `VFS.lookup(parent_id, name)` - Find a child node by name
- `VFS.move(node_id, new_parent_id, new_name)` - Move or rename a node
- `VFS.remove_by_id(node_id, opts)` - Delete a node

### Hardlink Operations
- `VFS.create_hardlink(parent_id, name, target_id)` - Create a POSIX hardlink
- `VFS.create_hardlink_to_virtual_inode(parent_id, name, torrent_file_id, opts)` - Create a virtual inode hardlink
- `VFS.is_hardlink?(node)` - Check if a node is a hardlink
- `VFS.extract_virtual_inode_id(node)` - Get the virtual inode ID from a hardlink
- `VFS.find_all_hardlinks_to_virtual_inode(inode_id)` - Find all hardlinks pointing to a virtual inode
- `VFS.count_hardlinks_to_virtual_inode(inode_id)` - Count hardlinks to a virtual inode

### Streaming Operations
- `VFS.Streamability.streamable?(node)` - Check if a node is streamable
- `VFS.Streamability.virtual_inode_streamable?(torrent_file)` - Check if a torrent file is streamable
- `VFS.Streamability.preload_for_streamability(nodes)` - Preload virtual inode data for batch checking

## Database Schema

### Nodes Table
- `id`: Primary key
- `parent_id`: Foreign key to parent node
- `name`: Filename or directory name
- `mode`: Unix-style file permissions (33188 for files, 16877 for directories)
- `content_type`: MIME type (e.g., "text/plain", "inode/directory")
- `size`: File size in bytes
- `data`: Binary data (used for storing hardlink target info)
- `is_hardlink`: Boolean flag (true if this is a hardlink)
- `hardlink_target_id`: For POSIX hardlinks, points to target node

## Design Principles

- **Single Source of Truth**: Only `torrent_files.link` determines streamability (no denormalization)
- **Smart Preloading**: Automatically detects when data is preloaded and avoids unnecessary queries
- **Idiomatic Elixir**: Clean, functional API with pattern matching and clear naming
- **Efficient Queries**: Batch operations and proper indexing for common access patterns
- **Race Condition Safe**: Transaction handling for concurrent access

## Integration with SyncEngine

The VFS module integrates with SyncEngine for torrent file management:

```elixir
# Create a hardlink to a torrent file from SyncEngine
{:ok, torrent_file} = SyncEngine.Torrents.get_torrent_file_by_id(torrent_file_id)
{:ok, hardlink} = VFS.create_hardlink_to_virtual_inode(
  parent_id,
  torrent_file.path,
  torrent_file.id,
  size: torrent_file.bytes
)

# Check if it's streamable
if VFS.Streamability.streamable?(hardlink) do
  # Can stream - torrent_file has a Real Debrid download link
end
```

## Examples

### Creating a Torrent Library Structure
```elixir
# Create root
{:ok, root} = VFS.get_root()

# Create movies directory
{:ok, movies} = VFS.create_directory(root.id, "movies")

# Add torrent files
{:ok, torrent_file} = SyncEngine.Torrents.get_torrent_file_by_id(123)
{:ok, hardlink} = VFS.create_hardlink_to_virtual_inode(
  movies.id,
  torrent_file.path,
  torrent_file.id,
  size: torrent_file.bytes
)
```

### Listing Streamable Files
```elixir
children = VFS.list_children(movies_id)
  |> VFS.Streamability.preload_for_streamability()

streamable_files = Enum.filter(children, &VFS.Streamability.streamable?/1)

Enum.each(streamable_files, fn file ->
  IO.puts("#{file.name} is streamable!")
end)
```

### Handling Hardlink Cascades
```elixir
# When deleting a torrent directory, cascade delete all hardlinks
VFS.remove_by_id(torrent_dir_id, cascade: true, cascade_hardlinks: true)
```
