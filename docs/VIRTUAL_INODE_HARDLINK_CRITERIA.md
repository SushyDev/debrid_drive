# Virtual Inode Hardlink Architecture: Zero-Data FUSE Model

## Overview

This implementation follows the **POSIX-idiomatic Virtual Inode (Ghost) with Zero Storage** model, standard in FUSE filesystems. The key insight: **the Linux kernel doesn't care where data comes from; it trusts the filesystem layer blindly.**

### The "Big Lie": Logical Size vs Physical Storage

- **`st_size` (Logical Size):** Reported to the OS as the full torrent file size (e.g., 4GB)
  - Video players see the "full file"
  - Kernel reports accurate sizes for `ls -lh`
  
- **`st_blocks` (Physical Disk Size):** Set to 0
  - `du -h` shows zero disk usage
  - Data streamed from network, never written to disk
  
- **`nlink` (Hardlink Count):** Tracked via `torrent_files.hardlink_count`
  - Incremented when a hardlink is created
  - Decremented when a hardlink is unlinked
  - Torrent removed from RealDebrid when ALL files' `hardlink_count == 0`

### Hardlink Detection (POSIX)

A node is a **hardlink** if and only if:
1. **Mode:** Regular file mode (`FileMode.regular?(mode)`)  ← This is the primary signal
2. **Data:** Numeric reference to virtual inode (`"vi:{id}"` or old-style `"{id}"`)

**NOT** by `content_type`. The `content_type` field is orthogonal to hardlink detection.

---

## Architecture: From Source+Link to Virtual Inode Only

**Old Model:**
- One "source" file node per torrent file (containing metadata)
- Hardlinks as separate references
- Deletion must track which is source vs link
- Confusing state management

**New Model (This Implementation):**
- NO source file nodes (zero local storage)
- Virtual inodes stored only in `torrent_files` table
- ALL VFS nodes that represent torrent files are hardlinks to a virtual inode
- Deletion uses reference counting (nlink-based)

---

## Architecture Changes

### 1. Virtual Inode Concept

**Virtual Inode** = A logical file backed by:
- RealDebrid metadata (file ID, path, size, link)
- No local Node in VFS (exists only in `torrent_files` table)
- Multiple hardlinks pointing to this virtual inode

#### Database Representation

```
┌──────────────────────────────────────────────────────────────┐
│ torrent_files (Virtual Inode Store)                          │
├──────────────────────────────────────────────────────────────┤
│ id (PK)                   INTEGER                            │
│ rd_id TEXT                                                   │
│ torrent_id (FK)           INTEGER                            │
│ path TEXT                 (Full path on RealDebrid)         │
│ bytes INTEGER             (File size)                        │
│ link TEXT                 (RealDebrid direct link)           │
│ download_link TEXT        (Cached download URL)             │
│ download_link_cached_at   DATETIME                          │
│ hardlink_count            INTEGER (denormalized, >= 1)      │
│ inserted_at               DATETIME                          │
│ updated_at                DATETIME                          │
└──────────────────────────────────────────────────────────────┘
           ↑ 1:N (each torrent file = 1 inode)
           │
     ┌─────┴──────────────────────────────────────┐
     │                                            │
┌────▼──────────────────────────┐   ┌────────────▼─────────────────┐
│ nodes (Hardlink References)    │   │ nodes (Regular Directories)  │
├───────────────────────────────┤   ├──────────────────────────────┤
│ id (PK)                       │   │ id (PK)                      │
│ parent_id                     │   │ parent_id                    │
│ name                          │   │ name                         │
│ mode (regular file mode)      │   │ mode (directory mode)        │
│ data: "vi:{torrent_file_id}"  │   │ (directory, no hardlink data)│
│ size (from virtual inode)     │   │ size, data, etc              │
│ content_type: null/any        │   │ content_type: (any)          │
└───────────────────────────────┘   └──────────────────────────────┘
  ↑ 1:N (multiple hardlinks             ↑ 1:N (directory tree)
       per inode)
```

**Key Change:** Store `torrent_file_id` (not `target_node_id`) in hardlink `data` field to reference virtual inode.

### Hardlink Detection: POSIX-Idiomatic Approach

**Detection Method:** A node is a hardlink if **both** conditions are true:

1. **Mode Check:** `FileMode.regular?(node.mode)` returns true
   - The node has a regular file mode (not directory, not symlink)
   - This is the PRIMARY signal that distinguishes hardlinks from regular files

2. **Data Check:** `node.data` is a numeric reference
   - Format: `"vi:{id}"` (virtual inode reference)  
   - OR: Just `"{id}"` (old-style backward compatibility)
   - Parsed via `VFS.extract_virtual_inode_id(data)`

**Implementation:**
```elixir
def is_hardlink?(node) do
  with true <- FileMode.regular?(node.mode),
       data when is_binary(data) and byte_size(data) > 0 <- node.data,
       {:ok, _} <- extract_virtual_inode_id(data) do
    true
  else
    _ -> false
  end
end
```

**Why NOT `content_type`?**
- `content_type` is advisory (e.g., "video/mp4", "application/pdf")
- It describes the file's semantic meaning, not its filesystem type
- A hardlink should have the same `content_type` as its target (or none)
- Mode is the canonical POSIX way to identify inode type

---

## Implementation Criteria

### Criterion 1: Sync Engine - File Creation (TorrentSync)

#### Current Behavior
```elixir
# apps/sync_engine/lib/sync_engine/services/torrent_sync.ex
defp add_torrent_file(torrent, torrent_node, rd_file, link) do
  # Creates a REAL file node
  {:ok, file_node} <- VFS.create_file(parent_node, sanitize_filename(filename),
    size: rd_file.bytes,
    content_type: "sync_engine/streamable"
  )
  
  # Links it to torrent_files table
  {:ok, _torrent_file} <- SyncEngine.Torrents.create_torrent_file(%{
    node_id: file_node.id  # References the SOURCE file
    # ...
  })
end
```

#### New Behavior: Virtual Inode

**Step 1: Create virtual inode ONLY in `torrent_files` table (no VFS node)**

```elixir
defp add_torrent_file(torrent, torrent_node, rd_file, link) do
  normalized_path = String.trim_leading(rd_file.path, "/")
  path_parts = Path.split(normalized_path)
  filename = List.last(path_parts)
  dir_parts = Enum.slice(path_parts, 0..-2//1)

  with {:ok, parent_node} <- ensure_directory_structure(torrent_node.id, dir_parts),
       # ✅ CHANGE 1: Create torrent_file WITHOUT creating a file node
       {:ok, virtual_inode} <-
         SyncEngine.Torrents.create_torrent_file(%{
           rd_id: rd_file.id,
           path: rd_file.path,
           bytes: rd_file.bytes,
           selected: rd_file.selected,
           link: link,
           torrent_id: torrent.id,
           node_id: nil,  # ← No VFS node yet!
           hardlink_count: 1  # ← Initialize reference count
         }),
       # ✅ CHANGE 2: Create hardlink to virtual inode
       {:ok, _hardlink_node} <-
         VFS.create_hardlink_to_virtual_inode(
           parent_node,
           sanitize_filename(filename),
           virtual_inode.id,  # ← Reference virtual inode, not a file node
           size: rd_file.bytes
         ) do
    {:ok, virtual_inode}
  end
end
```

---

### Criterion 2: gRPC Unlink Handler

When user unlinks a file via `FileSystemService.Unlink`:

1. Identify if it's a virtual inode hardlink (format: `"vi:{torrent_file_id}"`)
2. Decrement `hardlink_count` in `torrent_files`
3. If count reaches 0, enqueue torrent deletion
4. Remove the hardlink node from VFS

---

### Criterion 3: Deletion Logic - User-Initiated (Unlink)

When user unlinks a hardlink, we decrement its `hardlink_count`. **Key Rule:** Only enqueue torrent deletion when **ALL files in the torrent have `hardlink_count == 0`**.

```
grpc.Unlink(hardlink_node_id)
  ↓
Extract virtual_inode_id from hardlink_node.data
  ↓
Decrement hardlink_count in torrent_files[virtual_inode_id]
  ↓
Check: Are ALL files in this torrent's hardlink_count == 0?
  ├─ YES: Enqueue full torrent deletion (JobQueue)
  │       ↓
  │       Remove hardlink node
  │       Delete torrent from RealDebrid
  │
  └─ NO: Just remove hardlink node
         Leave torrent on RealDebrid
         Other files' hardlinks still exist
```

**Why "ALL files"?**
- A multi-file torrent (e.g., 5 video files) has one entry in `torrents` and multiple entries in `torrent_files`
- Each file tracks its own `hardlink_count` independently
- Only when EVERY file in the torrent has no hardlinks can we safely remove the torrent from RealDebrid
- This prevents orphaning data on remote storage

---

### Criterion 4: Deletion Logic - Remote Sync (Torrent Removed)

When RealDebrid removes torrent and sync detects it missing:

```
RealDebrid API: [torrent_123 DELETED]
  ↓
TorrentSync.sync() detects missing
  ↓
remove_torrent(db_torrent)
  ├─ Find all virtual inodes
  ├─ Delete ALL hardlinks for each inode
  ├─ Delete torrent record (cascades to virtual inodes)
  └─ Delete torrent directory tree (cascade)
```

**Behavior Difference:**
- **User Unlink:** Only delete if last link
- **Remote Deletion:** Delete all immediately (override)

---

### Criterion 5: Hardlink Count Tracking

#### Database Schema Changes

```elixir
# Add to torrent_files:
field :hardlink_count, :integer, default: 1

# Make node_id nullable:
field :node_id, :integer, null: true
```

#### Operations

```elixir
# Increment on new hardlink
def increment_hardlink_count(torrent_file)

# Decrement on unlink
def decrement_hardlink_count(torrent_file) → {new_count, should_delete_torrent}

# Verify consistency (for verifier)
def verify_hardlink_count(virtual_inode)
```

---

### Criterion 6: Virtual Inode Format

Hardlinks to virtual inodes store:
```
data = "vi:#{torrent_file_id}"

Example: "vi:123" means hardlink points to torrent_files.id=123
```

This distinguishes from old-style hardlinks which store target node IDs.

---

## Summary Table: Deletion Logic

| Trigger | Action | Hardlinks | Virtual Inode | Torrent Record |
| :--- | :--- | :--- | :--- | :--- |
| **User unlinks** (count > 1) | Remove hardlink node | ↓ count | Unchanged | Unchanged |
| **User unlinks** (count == 1) | Remove hardlink + enqueue API deletion | Delete link | Keep until sync confirms | Mark pending_deletion |
| **Next Sync** (torrent gone) | Cascade delete all hardlinks | Delete all | Delete (cascade) | Delete |
| **RealDebrid API confirms** | Mark deletion_status = deleted | N/A | N/A | Cleanup |

---

## Testing Checklist

- [ ] Create torrent with multiple files
- [ ] Create hardlink to file (verify hardlink_count increments)
- [ ] Unlink hardlink (verify hardlink_count decrements)
- [ ] Unlink original when count=1 (verify enqueues deletion)
- [ ] Create hardlinks, then delete torrent from RealDebrid
- [ ] Verify all hardlinks deleted in cascade
- [ ] Verify orphaned virtual inodes detected by verifier
- [ ] Backward compatibility: old hardlinks still work
- [ ] gRPC unlink RPC works correctly
- [ ] All existing tests still pass

