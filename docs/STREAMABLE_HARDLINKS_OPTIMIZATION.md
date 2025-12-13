# Streamable Hardlinks: Performance Optimization Strategy

## Problem Statement

The original code determines if a hardlink is "streamable" by:
1. Checking if the node is a hardlink
2. Extracting the virtual inode ID from `node.data`
3. Querying the database for `torrent_files` to check if `link IS NOT NULL`
4. Recursively calling `is_streamable?`

This requires a database query every time a hardlink's streamability is checked, even if the answer was determined moments before.

## Why NOT Denormalize

**Initial Approach:** Add a `streamable` boolean column to the `nodes` table, set when the hardlink is created.

**Problem:** **Desynchronization Risk**

Without database-level guarantees (e.g., triggers), the denormalized flag can become stale:

1. **Direct SQL updates** - If the `torrent_files.link` field is updated via raw SQL, the hardlinks' `streamable` flags won't update
2. **Cascade deletes** - If hardlinks are deleted via cascade without going through application code, the cache management doesn't run
3. **Concurrent updates** - Multiple processes updating the same torrent_file
4. **Code path bypasses** - Future developers might update torrent_files without knowing about the cache

**Result:** The source-of-truth splits, and inconsistencies are silent and hard to debug.

## Recommended: Smart Lazy Loading

**Strategy:** Optimize at the query level, not the schema level.

### Implementation Pattern

```elixir
# Pattern 1: Preload in queries where streamability matters
def lookup(parent_id, name) do
  from(n in Node,
    where: n.parent_id == ^parent_id and n.name == ^name,
    preload: [virtual_inode: :torrent_files]  # Load target in same query
  )
  |> Repo.one()
end

# Pattern 2: is_streamable? uses preloaded data if available
defp is_streamable?(node) do
  case VFS.extract_virtual_inode_id(node) do
    {:ok, inode_id} ->
      # If preloaded, use cached data; else query once
      case resolve_link_target(node) do
        {:ok, torrent_file} -> not is_nil(torrent_file.link)
        _ -> false
      end
    {:error, _} -> false
  end
end

# Pattern 3: resolve_link_target checks preloaded association first
defp resolve_link_target(node) do
  case node.__struct__ do
    VFS.Node ->
      # Try preloaded torrent_file first
      case Ecto.assoc_loaded?(node, :torrent_file) do
        true -> {:ok, node.torrent_file}
        false -> SyncEngine.Torrents.get_torrent_file_by_id(node.hardlink_target_id)
      end
  end
end
```

### Performance Profile

| Scenario | Approach | Complexity |
|----------|----------|-----------|
| **Single lookup** | Preload in query | O(1) - single query with join |
| **Multiple nodes** | Preload with `:include` | O(n) - single query with left joins |
| **Fallback (not preloaded)** | Single query per node | O(log n) - indexed `torrent_files(id)` |

### Advantages

✅ **Single source of truth** - `torrent_files.link` is the only canonical source  
✅ **No sync issues** - Impossible to desync  
✅ **Optimizable** - Query planner can optimize preloaded joins  
✅ **Backward compatible** - Works with existing code paths  
✅ **Testable** - No hidden state to maintain  

### Implementation Steps

1. **Identify hotspots** - Find code paths that check `is_streamable?` repeatedly
2. **Add preloading** - Update queries to preload `torrent_files` when needed
3. **Verify indexes** - Ensure `torrent_files(id)` and `torrent_files(streamable_column)` are indexed
4. **Benchmark** - Measure query counts before/after preloading

### Example: gRPC Lookup Handler

```elixir
def lookup(%LookupRequest{node_id: node_id, name: name}, _stream) do
  case VFS.lookup_with_preload(node_id, name) do  # NEW: preload torrent_file
    {:ok, node} ->
      # is_streamable? now has preloaded data, no extra query
      %LookupResponse{node: node_to_proto(node)}
    {:error, :not_found} ->
      %LookupResponse{}
  end
end
```

## Conclusion

**Denormalization without guarantees is dangerous.** The current approach—querying on-demand with Ecto's query caching—is actually optimal for:
- Correctness (no stale data)
- Maintainability (single source of truth)
- Performance (one extra query with indexed lookup, or zero with preloading)

The key optimization is **strategic preloading in hot paths**, not denormalization.
