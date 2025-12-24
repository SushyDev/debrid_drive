defmodule VFS.Streamability do
  @moduledoc """
  Streamability detection for virtual inodes (torrent files from Real Debrid).

  A node is **streamable** if it is a virtual inode (torrent file), regardless of
  whether a download link is currently cached. Download links are fetched on-demand
  with automatic caching and expiration handling.

  This module provides:
  - `streamable?/1` - Check if a node is a virtual inode (streamable)
  - `virtual_inode_has_link?/1` - Check if a torrent file has a cached link
  - `preload_for_streamability/1` - Preload virtual inodes for efficient batch checking

  ## Usage Examples

  ### Check if a node is streamable
  ```elixir
  inode = VFS.get_node(node_id)
  if VFS.Streamability.streamable?(inode) do
    # This is a virtual inode - use streaming API
  end
  ```

  ### Check if a link is currently cached (diagnostic)
  ```elixir
  torrent_file = SyncEngine.Torrents.get_torrent_file_by_id(id)
  if VFS.Streamability.virtual_inode_has_link?(torrent_file) do
    # Has a cached link (but will be fetched on-demand if expired)
  end
  ```

  ## Design Philosophy

  - **Simple streamability**: A virtual inode is always streamable
  - **On-demand links**: Links are fetched when needed, not checked upfront
  - **Automatic caching**: Links are cached with expiration for 4 hours
  - **Zero synchronization issues**: No cached state to become stale
  """

  alias VFS.{Inode, Repo}

  # Suppress warnings for SyncEngine module references (circular dependency at compile time, resolved at runtime)
  @compile {:no_warn_undefined, SyncEngine.Torrents}

  @doc """
  Determines if an inode is streamable.

  An inode is streamable if it's a virtual inode (torrent file from Real Debrid).
  This means it has both virtual_inode_type and virtual_inode_id set.

  Note: This does NOT check if a download link is available. Links are fetched
  on-demand with caching when get_stream_url is called.

  ## Examples
      iex> inode = %VFS.Inode{virtual_inode_type: "torrent_file", virtual_inode_id: 123}
      iex> VFS.Streamability.streamable?(inode)
      true

      iex> inode = %VFS.Inode{virtual_inode_type: nil}
      iex> VFS.Streamability.streamable?(inode)
      false
  """
  @spec streamable?(Inode.t() | map()) :: boolean()
  def streamable?(%Inode{} = inode) do
    # A virtual inode (torrent file) is streamable
    VFS.is_virtual_inode?(inode)
  end

  # For map structs (like torrent_file), check if it has an id field
  # This avoids a direct dependency on SyncEngine.Schemas.TorrentFile
  def streamable?(map) when is_map(map) do
    # If it's a torrent_file struct, it's streamable
    Map.has_key?(map, :real_debrid_torrent_file_id)
  end

  def streamable?(_), do: false

  @doc """
  Checks if a virtual inode (torrent_file) has a download link available.

  Note: This is different from streamable?/1. A torrent file is always streamable
  (can use the streaming API), but this function checks if a link is currently available.
  Links are fetched on-demand, so this is mainly useful for diagnostics.

  ## Examples
      iex> torrent_file = %{link: "https://real-debrid.com/..."}
      iex> VFS.Streamability.virtual_inode_has_link?(torrent_file)
      true

      iex> torrent_file = %{link: nil}
      iex> VFS.Streamability.virtual_inode_has_link?(torrent_file)
      false
  """
  @spec virtual_inode_has_link?(map()) :: boolean()
  def virtual_inode_has_link?(map) when is_map(map) do
    case Map.fetch(map, :link) do
      {:ok, link} -> not is_nil(link)
      :error -> false
    end
  end

  def virtual_inode_has_link?(_), do: false

  # Deprecated: Use virtual_inode_has_link?/1 instead
  @deprecated "Use virtual_inode_has_link?/1 instead"
  def virtual_inode_streamable?(map), do: virtual_inode_has_link?(map)

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
end
