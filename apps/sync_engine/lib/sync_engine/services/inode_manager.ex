defmodule SyncEngine.Services.InodeManager do
  @moduledoc """
  Manages VFS inode updates for torrent files.

  Handles the logic of updating VFS inodes to point to the most recent
  torrent_file when multiple torrent instances share the same file.
  """

  require Logger
  alias VFS
  alias SyncEngine.Queries.TorrentFileQueries

  @doc """
  Updates a VFS inode to point to the most recent torrent_file for the given hash and path.

  This is used in two scenarios:
  1. When adding a duplicate file (merge + upsert)
  2. When deleting a torrent and updating remaining files to point to next most recent

  Returns:
  - `{:ok, updated_inode}` if successful
  - `{:error, :no_files_found}` if no torrent_files exist for this hash/path
  - `{:error, reason}` for other errors
  """
  def update_to_most_recent(inode, hash, path) do
    case TorrentFileQueries.find_most_recent(hash, path) do
      nil ->
        Logger.warning("No torrent files found for hash #{hash} path #{path} when updating inode #{inode.inode_id}")

        {:error, :no_files_found}

      most_recent_file ->
        update_inode_to_file(inode, most_recent_file)
    end
  end

  @doc """
  Updates a VFS inode to point to a specific torrent_file.

  Used when we've already identified which file the inode should point to.
  """
  def update_inode_to_file(inode, torrent_file) do
    case VFS.update_node(inode.inode_id, %{
           virtual_inode_id: torrent_file.id,
           size: torrent_file.bytes
         }) do
      {:ok, updated_inode} ->
        Logger.debug("Updated VFS inode #{inode.inode_id} to point to torrent_file #{torrent_file.id}")

        {:ok, updated_inode}

      {:error, reason} = error ->
        Logger.error("Failed to update VFS inode #{inode.inode_id} to torrent_file #{torrent_file.id}: #{inspect(reason)}")

        error
    end
  end
end
