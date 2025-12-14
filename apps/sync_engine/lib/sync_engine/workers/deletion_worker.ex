defmodule SyncEngine.Workers.DeletionWorker do
  @moduledoc """
  Simple wrapper for enqueuing torrent deletion jobs.

  This module provides a clean interface for deleting torrents asynchronously.
  The actual job processing is handled by SyncEngine.JobQueue.

  ## Usage

      # Delete a single torrent
      DeletionWorker.enqueue("abc123...")

      # Delete multiple torrents
      DeletionWorker.enqueue_batch(["abc123...", "def456..."])
  """

  @doc """
  Enqueues a deletion job for a torrent by hash.

  ## Examples

      iex> DeletionWorker.enqueue("abc123...")
      :ok

  """
  def enqueue(torrent_hash) when is_binary(torrent_hash) do
    SyncEngine.JobQueue.enqueue(:delete_torrent, %{torrent_hash: torrent_hash})
  end

  @doc """
  Enqueues deletion jobs for multiple torrents by hash.

  ## Examples

      iex> DeletionWorker.enqueue_batch(["abc123...", "def456..."])
      :ok

  """
  def enqueue_batch(torrent_hashes) when is_list(torrent_hashes) do
    Enum.each(torrent_hashes, fn torrent_hash ->
      enqueue(torrent_hash)
    end)

    :ok
  end
end
