defmodule VFS.Streamability do
  @moduledoc """
  Streamability detection for hardlinks to virtual inodes (torrent files).

  A node is **streamable** if and only if:
  1. It is a hardlink to a virtual inode (torrent_file)
  2. The target virtual inode has a download link from Real Debrid

  This module provides:
  - `streamable?/1` - Determine if a node is streamable (with smart preloading fallback)
  - `preload_for_streamability/1` - Preload virtual inodes for efficient batch checking
  - `virtual_inode_streamable?/1` - Check if a torrent_file is streamable

  ## Usage Examples

  ### Single Node (with automatic fallback)
  ```elixir
  node = VFS.get_node(node_id)
  if VFS.Streamability.streamable?(node) do
    # Can stream this file
  end
  ```

  ### Multiple Nodes (with preloading for efficiency)
  ```elixir
  nodes = VFS.list_children(parent_id)
    |> VFS.Streamability.preload_for_streamability()  # Load in single query

  Enum.each(nodes, fn node ->
    if VFS.Streamability.streamable?(node) do
      # Can stream - no extra queries!
    end
  end)
  ```

  ### Torrent Files
  ```elixir
  torrent_file = SyncEngine.Torrents.get_torrent_file_by_id(id)
  if VFS.Streamability.virtual_inode_streamable?(torrent_file) do
    # This virtual inode can be streamed
  end
  ```

  ## Performance Characteristics

  | Scenario | Behavior | Queries |
  |----------|----------|---------|
  | Preloaded node | Uses preloaded data | 0 |
  | Not preloaded hardlink | Queries torrent_file by ID | 1 |
  | Not preloaded regular file | No query needed | 0 |
  | Batch (preloaded) | All in one query | 1 |

  ## Design Philosophy

  - **Single source of truth**: Only `torrent_files.link` determines streamability
  - **Smart fallback**: Detects preloaded data automatically, queries only if needed
  - **Idiomatic Elixir**: Simple functions, pattern matching, clear naming
  - **Zero denormalization risk**: No cached state to desync
  """

  alias VFS.{Node, Repo}

  @doc """
  Determines if a node is streamable.

  A node is streamable if:
  1. It's a hardlink (via VFS.is_hardlink?/1)
  2. It points to a virtual inode (has hardlink_target_torrent_file_id set)
  3. The target virtual inode has a download link

  ## Strategy
  - If the node has a `torrent_file` field attached, uses that (zero queries)
  - If not but is a virtual inode hardlink, queries torrent_file by ID (one query)
  - Otherwise returns false (no query)

  Also accepts map structs (like torrent_file) directly.

  ## Examples
      iex> node = %VFS.Node{is_hardlink: true, hardlink_target_torrent_file_id: 123} |> Map.put(:torrent_file, %{link: "https://..."})
      iex> VFS.Streamability.streamable?(node)
      true

      iex> node = %VFS.Node{is_hardlink: false}
      iex> VFS.Streamability.streamable?(node)
      false
  """
  @spec streamable?(Node.t() | map()) :: boolean()
  def streamable?(%Node{} = node) do
    # Only hardlinks can be streamable
    if VFS.is_hardlink?(node) do
      check_hardlink_streamability(node)
    else
      false
    end
  end

  # Check if it's a torrent_file struct by checking if it has a :link field
  # This avoids a direct dependency on SyncEngine.Schemas.TorrentFile
  def streamable?(map) when is_map(map) do
    case Map.fetch(map, :link) do
      {:ok, link} -> not is_nil(link)
      :error -> false
    end
  end

  def streamable?(_), do: false

  @doc """
  Checks if a virtual inode (torrent_file) is streamable.

  A virtual inode is streamable if it has a link field set.

  ## Examples
      iex> torrent_file = %{link: "https://real-debrid.com/..."}
      iex> VFS.Streamability.virtual_inode_streamable?(torrent_file)
      true

      iex> torrent_file = %{link: nil}
      iex> VFS.Streamability.virtual_inode_streamable?(torrent_file)
      false
  """
  @spec virtual_inode_streamable?(map()) :: boolean()
  def virtual_inode_streamable?(map) when is_map(map) do
    case Map.fetch(map, :link) do
      {:ok, link} -> not is_nil(link)
      :error -> false
    end
  end

  def virtual_inode_streamable?(_), do: false

  @doc """
  Preloads virtual inodes for a list of nodes efficiently.

  For all hardlinks in the list that point to virtual inodes, this loads their
  target torrent_files in a single query. This allows subsequent
  calls to `streamable?/1` to have zero additional queries.

  ## Usage
      nodes = VFS.list_children(parent_id)
      nodes = VFS.Streamability.preload_for_streamability(nodes)

      # Now all streamable? checks use preloaded data
      Enum.map(nodes, fn node ->
        {node.name, VFS.Streamability.streamable?(node)}
      end)

  ## Performance
  - Time: O(n log n) where n = number of nodes (due to sorting)
  - Queries: 1 (single query)
  - Compared to: n queries without preloading
  """
  @spec preload_for_streamability([Node.t()]) :: [Node.t()]
  def preload_for_streamability(nodes) when is_list(nodes) do
    # Extract virtual inode IDs from hardlinks with hardlink_target_torrent_file_id
    virtual_inode_ids =
      nodes
      |> Enum.filter(&VFS.is_hardlink?/1)
      |> Enum.filter(fn node -> !is_nil(node.hardlink_target_torrent_file_id) end)
      |> Enum.map(fn node -> node.hardlink_target_torrent_file_id end)
      |> Enum.uniq()

    # Load all virtual inodes in a single query
    torrent_files_map =
      if Enum.empty?(virtual_inode_ids) do
        %{}
      else
        # Query just the id and link fields
        # Using raw SQL to avoid schema dependency and circular imports
        query_str =
          "SELECT id, link FROM torrent_files WHERE id IN (" <>
            Enum.map_join(virtual_inode_ids, ", ", fn _ -> "?" end) <> ")"

        case Repo.query(query_str, virtual_inode_ids) do
          {:ok, %{rows: rows}} ->
            rows
            |> Enum.map(fn [id, link] ->
              {id, %{id: id, link: link}}
            end)
            |> Map.new()

          {:error, _} ->
            # If query fails, fall back to no preloading
            %{}
        end
      end

    # Inject preloaded torrent_files into nodes
    Enum.map(nodes, fn node ->
      case node.hardlink_target_torrent_file_id do
        nil ->
          node

        inode_id ->
          case Map.fetch(torrent_files_map, inode_id) do
            {:ok, torrent_file} ->
              # Inject as a plain map field
              Map.put(node, :torrent_file, torrent_file)

            :error ->
              node
          end
      end
    end)
  end

  def preload_for_streamability(non_list), do: non_list

  # Private: Check if a hardlink node is streamable
  defp check_hardlink_streamability(node) do
    # For virtual inode hardlinks, check if the target has a link
    case node.hardlink_target_torrent_file_id do
      nil ->
        # Regular POSIX hardlink (not virtual inode) - never streamable
        false

      inode_id ->
        # Virtual inode hardlink - try to get the virtual inode
        case get_virtual_inode(node, inode_id) do
          {:ok, torrent_file} -> virtual_inode_streamable?(torrent_file)
          {:error, _} -> false
        end
    end
  end

  # Private: Get virtual inode, preferring preloaded data
  defp get_virtual_inode(node, inode_id) do
    # Check if torrent_file is already attached to the node
    case Map.get(node, :torrent_file) do
      nil ->
        # Not preloaded, query by ID
        SyncEngine.Torrents.get_torrent_file_by_id(inode_id)

      torrent_file when is_map(torrent_file) ->
        # Preloaded or manually set map
        {:ok, torrent_file}

      _ ->
        # Some other value, try querying
        SyncEngine.Torrents.get_torrent_file_by_id(inode_id)
    end
  end
end
