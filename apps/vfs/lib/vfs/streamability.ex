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

  alias VFS.{Inode, Repo}

  @doc """
  Determines if an inode is streamable.

  An inode is streamable if:
  1. It's a virtual inode (has virtual_inode_type and virtual_inode_id)
  2. The target virtual inode has a download link

  ## Strategy
  - If the inode has a `torrent_file` field attached, uses that (zero queries)
  - If not but is a virtual inode, queries torrent_file by ID (one query)
  - Otherwise returns false (no query)

  Also accepts map structs (like torrent_file) directly.

  ## Examples
      iex> inode = %VFS.Inode{virtual_inode_type: "torrent_file", virtual_inode_id: 123} |> Map.put(:torrent_file, %{link: "https://..."})
      iex> VFS.Streamability.streamable?(inode)
      true

      iex> inode = %VFS.Inode{virtual_inode_type: nil}
      iex> VFS.Streamability.streamable?(inode)
      false
  """
  @spec streamable?(Inode.t() | map()) :: boolean()
  def streamable?(%Inode{} = inode) do
    # Only virtual inodes can be streamable
    if inode.virtual_inode_type == "torrent_file" and not is_nil(inode.virtual_inode_id) do
      check_virtual_inode_streamability(inode)
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
  Preloads virtual inodes for a list of inodes efficiently.

  For all inodes in the list that are virtual inodes (torrent_files), this loads their
  torrent_file data in a single query. This allows subsequent
  calls to `streamable?/1` to have zero additional queries.

  ## Usage
      children = VFS.list_children(parent_id)
      inodes = Enum.map(children, fn {_entry, inode} -> inode end)
      inodes = VFS.Streamability.preload_for_streamability(inodes)

      # Now all streamable? checks use preloaded data
      Enum.zip(children, inodes)
      |> Enum.map(fn {{entry, _old_inode}, preloaded_inode} ->
        {entry.name, VFS.Streamability.streamable?(preloaded_inode)}
      end)

  ## Performance
  - Time: O(n log n) where n = number of inodes (due to sorting)
  - Queries: 1 (single query)
  - Compared to: n queries without preloading
  """
  @spec preload_for_streamability([Inode.t()]) :: [Inode.t()]
  def preload_for_streamability(inodes) when is_list(inodes) do
    # Extract virtual inode IDs from virtual inodes (torrent_file type)
    virtual_inode_ids =
      inodes
      |> Enum.filter(fn inode ->
        inode.virtual_inode_type == "torrent_file" and not is_nil(inode.virtual_inode_id)
      end)
      |> Enum.map(fn inode -> inode.virtual_inode_id end)
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

    # Inject preloaded torrent_files into inodes
    Enum.map(inodes, fn inode ->
      case inode.virtual_inode_id do
        nil ->
          inode

        vid ->
          case Map.fetch(torrent_files_map, vid) do
            {:ok, torrent_file} ->
              # Inject as a plain map field
              Map.put(inode, :torrent_file, torrent_file)

            :error ->
              inode
          end
      end
    end)
  end

  def preload_for_streamability(non_list), do: non_list

  # Private: Check if a virtual inode is streamable
  defp check_virtual_inode_streamability(inode) do
    # Virtual inode - try to get the torrent_file data
    case inode.virtual_inode_id do
      nil ->
        false

      vid ->
        # Try to get the virtual inode (torrent_file)
        case get_virtual_inode(inode, vid) do
          {:ok, torrent_file} -> virtual_inode_streamable?(torrent_file)
          {:error, _} -> false
        end
    end
  end

  # Private: Get virtual inode, preferring preloaded data
  defp get_virtual_inode(inode, vid) do
    # Check if torrent_file is already attached to the inode
    case Map.get(inode, :torrent_file) do
      nil ->
        # Not preloaded, query by ID
        SyncEngine.Torrents.get_torrent_file_by_id(vid)

      torrent_file when is_map(torrent_file) ->
        # Preloaded or manually set map
        {:ok, torrent_file}

      _ ->
        # Some other value, try querying
        SyncEngine.Torrents.get_torrent_file_by_id(vid)
    end
  end
end
