defmodule SyncEngine.Services.DeletionPolicy do
  @moduledoc """
  Determines when torrents should be deleted from Real-Debrid.

  Deletion policy: A torrent should be deleted from Real-Debrid when
  all user-visible references (hardlinks) to its files have been removed.
  """

  require Logger
  alias SyncEngine.Queries.TorrentFileQueries
  alias SyncEngine.Workers.DeletionWorker

  @doc """
  Checks if a torrent should be deleted from Real-Debrid.

  A torrent should be deleted when all its files have zero hardlinks,
  meaning no user-visible references exist in the VFS.

  Returns `true` if deletion should proceed, `false` otherwise.
  """
  def should_delete_torrent?(hash, torrent_rd_id) do
    TorrentFileQueries.all_hardlinks_zero?(hash, torrent_rd_id)
  end

  @doc """
  Enqueues a torrent deletion if the deletion policy allows it.

  Checks if all hardlinks are removed, and if so, enqueues a deletion job.

  Returns:
  - `:enqueued` if deletion was queued
  - `:skipped` if deletion was not needed (hardlinks still exist)
  """
  def maybe_enqueue_deletion(hash, torrent_rd_id) do
    if should_delete_torrent?(hash, torrent_rd_id) do
      Logger.info("All hardlinks removed for torrent #{torrent_rd_id}, enqueueing deletion from RealDebrid")

      DeletionWorker.enqueue(torrent_rd_id)
      :enqueued
    else
      Logger.debug("Skipping deletion for torrent #{torrent_rd_id} - hardlinks still exist")
      :skipped
    end
  end
end
