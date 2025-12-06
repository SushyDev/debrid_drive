# Deletion Specification

## Overview

This document specifies the deletion behavior for the debrid_drive_ex system, which handles two types of deletions:

1. **Immediate VFS Deletions**: Local nodes (directories, user-created files, hard links) are deleted immediately
2. **Deferred API Deletions**: Torrent-backed files trigger API deletion and are cleaned up by the next sync cycle

## Architecture Principles

### Separation of Concerns

- **VFS Layer**: Manages the local filesystem tree structure and enforces referential integrity
- **gRPC Layer**: Orchestrates deletion logic and determines if API cleanup is needed
- **SyncEngine Layer**: Handles Real-Debrid API deletions and reconciles VFS state during sync

### Eventual Consistency

- Torrent deletions are eventually consistent - API calls happen async, VFS cleanup happens on next sync
- Local deletions are immediately consistent - VFS changes are atomic and transactional

## Deletion Rules

### 1. Regular File Deletion (No Torrent Backing)

**Scenario**: User-created file with no associated torrent

```
VFS Tree:
  /root
    └── user_notes.txt (no torrent_file)
    
Delete: user_notes.txt
```

**Behavior**:
- ✅ Immediate deletion from VFS
- ✅ Single database transaction
- ❌ No API call needed

**Implementation**: VFS `remove/2` + database DELETE

---

### 2. Torrent File Deletion (Last Reference)

**Scenario**: Deleting the last reference to a torrent file

```
VFS Tree:
  /root
    └── movie.mkv (node_id=100, torrent_file_id=50, torrent_id=10)
    
Delete: movie.mkv
```

**Behavior**:
1. ✅ Mark node for deletion (soft delete or flag)
2. ✅ Queue torrent deletion via Real-Debrid API
3. ✅ Sync engine processes the queue asynchronously
4. ✅ On next sync: Verify torrent is gone from API
5. ✅ Remove VFS nodes for all files in that torrent including hardlink references and any references to those recursively, also cleanup empty directories of torrents (only torrents not user created empty directories)
6. ✅ Remove torrent_files records
7. ✅ Remove torrent record

**Implementation**: 
- gRPC layer checks `torrent_files` association
- Calls `SyncEngine.Torrents.delete_torrent/1`
- Sync engine marks torrent as "pending_deletion"
- Background worker calls Real-Debrid delete API
- Next sync reconciles and removes VFS nodes

---

### 3. Hard Link Deletion (Target Still Has References)

**Scenario**: Delete a hard link when other hard links or the target still exist

```
VFS Tree:
  /root
    ├── movies/
    │   └── original.mkv (node_id=100, torrent_file)
    ├── link1.mkv (node_id=101, hardlink -> 100)
    └── link2.mkv (node_id=102, hardlink -> 100)
    
Delete: link1.mkv
```

**Behavior**:
- ✅ Immediate deletion of hard link node (101)
- ✅ Target node (100) remains untouched
- ✅ Other hard links (102) remain untouched
- ❌ No API call - target still exists

**Implementation**: VFS `remove/2` deletes the hard link node only

---

### 4. Hard Link Deletion (Last Reference to Target)

**Scenario**: Delete the last hard link pointing to a torrent file

```
VFS Tree:
  /root
    ├── movies/
    │   └── original.mkv (node_id=100, torrent_file, deleted)
    └── last_link.mkv (node_id=101, hardlink -> 100)
    
Delete: last_link.mkv
```

**Behavior**:
1. ✅ Delete hard link node (101) immediately
2. ✅ Check if target (100) has any remaining hard links
3. ✅ If no more hard links AND target is torrent-backed:
   - Queue torrent deletion via API
   - Sync will clean up on next cycle
4. ❌ If target was already deleted, just remove the hard link

**Implementation**: 
- VFS deletes hard link node
- gRPC checks: `count_hardlinks_to_target(100) == 0`
- If true, trigger torrent deletion workflow

---

### 5. Torrent File Deletion with Existing Hard Links

**Scenario**: Delete the original torrent file when hard links still exist

```
VFS Tree:
  /root
    ├── movies/
    │   └── original.mkv (node_id=100, torrent_file)
    ├── link1.mkv (node_id=101, hardlink -> 100)
    └── link2.mkv (node_id=102, hardlink -> 100)
    
Delete: original.mkv
```

**Behavior**:
1. ✅ Delete original file node (100) immediately
2. ✅ Hard links (101, 102) become **orphaned** (point to non-existent node)
3. ❌ **DO NOT** trigger API deletion yet - hard links still exist
4. ✅ When last orphaned hard link is deleted:
   - Trigger torrent deletion
   - Sync cleans up

**Alternative Behavior** (Cascade Delete):
1. ✅ Delete original file node (100)
2. ✅ Find all hard links pointing to 100
3. ✅ Delete all hard links (101, 102) in same transaction
4. ✅ Trigger torrent deletion
5. ✅ Sync cleans up

**Recommended**: **Cascade Delete** - prevents orphaned hard links

---

### 6. Directory Deletion with Torrent Files

**Scenario**: Delete directory containing torrent-backed files

```
VFS Tree:
  /root
    └── movies/
        ├── movie1.mkv (torrent_file_id=50)
        ├── movie2.mkv (torrent_file_id=51)
        └── subfolder/
            └── movie3.mkv (torrent_file_id=52)
            
Delete: movies/
```

**Behavior**:
1. ✅ Recursively find all descendant nodes
2. ✅ Collect all unique torrent_ids from torrent-backed files
3. ✅ Queue all torrents for deletion via API
4. ✅ Mark directory and all descendants as "pending_deletion"
5. ✅ Sync engine processes deletions
6. ✅ On next sync: Remove entire tree

**Edge Case - Hard Links Outside Directory**:
```
VFS Tree:
  /root
    ├── movies/
    │   └── movie.mkv (node_id=100, torrent_file)
    └── favorites/
        └── link.mkv (node_id=101, hardlink -> 100)
        
Delete: movies/
```

**Behavior**:
- ✅ Delete `movies/movie.mkv` (node 100)
- ✅ Hard link in `favorites/link.mkv` (101) becomes orphaned
- ❌ Do NOT delete torrent yet (hard link still references it)
- ✅ When `favorites/link.mkv` is deleted, trigger torrent deletion

**Recommended**: **Cascade hard link deletion** when deleting a directory:
1. Find all nodes in directory tree
2. For each torrent-backed file, find all hard links (inside AND outside directory)
3. Delete all hard links as part of the same operation
4. Then trigger torrent deletion

---

### 7. Directory Deletion with Mixed Content

**Scenario**: Directory with local files, torrent files, and hard links

```
VFS Tree:
  /root
    └── mixed/
        ├── notes.txt (local file)
        ├── movie.mkv (torrent_file)
        └── link.mkv (hardlink -> external node)
        
Delete: mixed/
```

**Behavior**:
1. ✅ `notes.txt` deleted immediately (local)
2. ✅ `movie.mkv` queued for API deletion
3. ✅ `link.mkv` deleted immediately (just the hard link)
4. ✅ Directory deleted immediately
5. ✅ Sync cleans up torrent files later

---

## Database Schema Changes

### Add Deletion Status to Nodes (Optional)

```sql
ALTER TABLE nodes ADD COLUMN deletion_status TEXT DEFAULT 'active';
-- Values: 'active', 'pending_deletion', 'deleted'
```

This allows soft-delete approach for torrent files while keeping VFS responsive.

### Add Deletion Queue to Torrents

```sql
ALTER TABLE torrents ADD COLUMN deletion_requested_at DATETIME;
ALTER TABLE torrents ADD COLUMN deletion_status TEXT DEFAULT 'active';
-- Values: 'active', 'pending_deletion', 'deletion_failed', 'deleted'
```

---

## API Integration

### Real-Debrid Torrent Deletion

**Endpoint**: `DELETE /torrents/delete/{id}`

**Implementation in SyncEngine**:

```elixir
defmodule SyncEngine.Api.RealDebrid.Torrents do
  def delete_torrent(client, torrent_rd_id) do
    # Call Real-Debrid API
    # Returns :ok or {:error, reason}
  end
end
```

### Deletion Worker

```elixir
defmodule SyncEngine.Workers.DeletionWorker do
  use Oban.Worker, queue: :deletions, max_attempts: 3
  
  def perform(%{args: %{"torrent_id" => torrent_id}}) do
    # 1. Fetch torrent record
    # 2. Call Real-Debrid API to delete
    # 3. Update torrent.deletion_status
    # 4. On next sync, remove VFS nodes
  end
end
```

---

## Transactional Guarantees

### VFS Layer (SQLite Transactions)

```elixir
Repo.transaction(fn ->
  # Delete node(s)
  # Delete associated hard links (if cascade)
  # Update parent directory timestamps
end)
```

### gRPC Layer (Two-Phase)

```elixir
# Phase 1: VFS Changes (atomic)
Repo.transaction(fn ->
  VFS.remove(node_id)
  if torrent_backed?, do: mark_for_deletion(node_id)
end)

# Phase 2: Queue API Work (async)
if torrent_backed? do
  SyncEngine.Torrents.queue_deletion(torrent_id)
end
```

### Sync Engine (Idempotent Reconciliation)

```elixir
# On each sync:
1. Fetch active torrents from Real-Debrid API
2. Compare with local torrents marked "pending_deletion"
3. If torrent is gone from API:
   - Remove associated VFS nodes
   - Remove torrent_files records
   - Remove torrent record
   - Remove empty parent directory node
4. If torrent still exists in API:
   - Retry deletion (with exponential backoff)
```

---

## Error Handling

### API Deletion Failures

**Scenario**: Real-Debrid API returns error or is unreachable

**Behavior**:
1. ✅ VFS nodes remain marked "pending_deletion"
2. ✅ Retry deletion on next sync (max 3 attempts)
3. ✅ After max attempts, mark as "deletion_failed"
4. ✅ Log error for manual intervention
5. ❌ Do not delete VFS nodes until API confirms deletion

### Partial Failures in Directory Deletion

**Scenario**: Some torrents delete successfully, others fail

**Behavior**:
1. ✅ Track deletion status per torrent
2. ✅ Successfully deleted torrents are cleaned up
3. ✅ Failed torrents remain with "deletion_failed" status
4. ✅ User can retry deletion or manually intervene

---

## Test Cases

### VFS Layer Tests (`apps/vfs/test/vfs_deletion_test.exs`)

1. ✅ Delete regular file
2. ✅ Delete hard link (target remains)
3. ✅ Delete directory (empty)
4. ✅ Delete directory (with files)
5. ✅ Delete directory (with hard links pointing in)
6. ✅ Prevent deletion of non-empty directory (without cascade flag)
7. ✅ Cascade delete directory (removes all children)
8. ✅ Transaction rollback on error

### gRPC Layer Tests (`apps/grpc_server/test/e2e/deletion_test.exs`)

1. ✅ Remove regular file via gRPC
2. ✅ Remove hard link via gRPC
3. ✅ Remove last hard link (should NOT trigger API - covered by sync)
4. ✅ Remove torrent-backed file (marks for deletion)
5. ✅ Remove directory with mixed content
6. ✅ Remove directory with hard links outside (cascade)
7. ✅ Error handling: API unavailable
8. ✅ Error handling: Invalid node ID

### SyncEngine Tests (`apps/sync_engine/test/sync_engine/deletion_test.exs`)

1. ✅ Sync detects torrent marked for deletion
2. ✅ Call Real-Debrid delete API
3. ✅ Clean up VFS nodes after successful API deletion
4. ✅ Clean up torrent_files records
5. ✅ Clean up torrent record
6. ✅ Handle API errors gracefully
7. ✅ Retry failed deletions
8. ✅ Idempotent sync (multiple syncs don't cause errors)
9. ✅ Reconcile: torrent deleted externally (cleanup VFS)
10. ✅ Reconcile: torrent reappeared (mark as active again)

### Integration Tests (`apps/grpc_server/test/e2e/deletion_integration_test.exs`)

1. ✅ End-to-end: Create torrent file → Create hard link → Delete both → Sync cleans up
2. ✅ End-to-end: Delete directory with torrents → Sync cleans up
3. ✅ End-to-end: Delete file → Create with same name → Ensure no conflicts
4. ✅ End-to-end: Concurrent deletions (multiple users)

---

## Implementation Plan

### Phase 1: VFS Layer
- [ ] Add `VFS.count_hardlinks_to_target/1`
- [ ] Add cascade delete logic to `VFS.remove/2`
- [ ] Write VFS deletion tests
- [ ] Implement and verify

### Phase 2: gRPC Layer
- [ ] Update `remove/2` to detect torrent-backed files
- [ ] Add logic to mark torrents for deletion
- [ ] Add cascade logic for directories
- [ ] Write gRPC deletion tests
- [ ] Implement and verify

### Phase 3: SyncEngine Layer
- [ ] Add `deletion_status` to torrents table
- [ ] Create deletion worker
- [ ] Add Real-Debrid delete API integration
- [ ] Update sync logic to handle pending deletions
- [ ] Write SyncEngine deletion tests
- [ ] Implement and verify

### Phase 4: Integration
- [ ] Write integration tests
- [ ] Test with real Real-Debrid API (staging)
- [ ] Performance testing (large directory deletions)
- [ ] Document edge cases and manual recovery procedures

---

## Open Questions

1. **Soft Delete vs Hard Delete**: Should we soft-delete nodes (mark as deleted) or hard-delete immediately?
   - **Recommendation**: Hard delete VFS nodes for local files, soft delete for torrent files until API confirms

2. **Orphaned Hard Link Behavior**: Allow orphaned hard links or cascade delete?
   - **Recommendation**: Cascade delete to prevent confusion

3. **Directory Deletion UX**: Require explicit cascade flag or always cascade?
   - **Recommendation**: Always cascade for simplicity

4. **Sync Frequency**: How often to reconcile deletions?
   - **Recommendation**: Every 15 seconds (current sync interval)

5. **Manual Deletion Recovery**: How should users recover from failed API deletions?
   - **Recommendation**: Add admin endpoint to retry or force cleanup

---

## Security Considerations

1. **Authorization**: Ensure user owns the torrent before deleting via API
2. **Rate Limiting**: Limit deletion requests to prevent abuse
3. **Audit Log**: Log all deletion requests (node_id, torrent_id, user, timestamp)
4. **Concurrent Access**: Handle race conditions (two users deleting same file)

---

## Performance Considerations

1. **Batch Deletions**: When deleting directory, batch API calls
2. **Async Processing**: Use Oban for async deletion queue
3. **Database Indexes**: Index `nodes.content_type` for hard link queries
4. **Cascading Deletes**: Use recursive CTEs for efficient tree traversal

---

## Monitoring and Observability

1. **Metrics**:
   - Deletion requests per minute
   - API deletion success rate
   - Average time from request to cleanup
   - Number of pending deletions

2. **Alerts**:
   - High number of failed deletions
   - Deletions stuck in pending state > 1 hour
   - API rate limit errors

3. **Logging**:
   - Log all deletion requests
   - Log API responses
   - Log cleanup operations

---

## Future Enhancements

1. **Batch Operations**: Delete multiple files in single gRPC call
2. **Undo Functionality**: Trash/recycle bin with restoration
3. **Selective Sync**: Only sync deletions for specific torrents
4. **Webhook Integration**: Real-Debrid webhook for instant cleanup notifications
5. **Quota Management**: Track storage usage and enforce limits
