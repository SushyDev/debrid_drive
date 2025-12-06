defmodule SyncEngine.Workers.DeletionWorker do
  @moduledoc """
  Simple wrapper for enqueuing torrent deletion jobs.

  This module provides a clean interface for deleting torrents asynchronously.
  The actual job processing is handled by SyncEngine.JobQueue.

  ## Usage

      # Delete a single torrent
      DeletionWorker.enqueue(123)

      # Delete multiple torrents
      DeletionWorker.enqueue_batch([1, 2, 3])
  """

  @doc """
  Enqueues a deletion job for a torrent.

  ## Examples

      iex> DeletionWorker.enqueue(123)
      :ok

  """
  def enqueue(torrent_id) when is_integer(torrent_id) do
    SyncEngine.JobQueue.enqueue(:delete_torrent, %{torrent_id: torrent_id})
  end

  @doc """
  Enqueues deletion jobs for multiple torrents.

  ## Examples

      iex> DeletionWorker.enqueue_batch([1, 2, 3])
      :ok

  """
  def enqueue_batch(torrent_ids) when is_list(torrent_ids) do
    Enum.each(torrent_ids, fn torrent_id ->
      enqueue(torrent_id)
    end)

    :ok
  end
end
