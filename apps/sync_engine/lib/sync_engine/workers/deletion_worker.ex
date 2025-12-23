defmodule SyncEngine.Workers.DeletionWorker do
  @moduledoc """
  Simple wrapper for enqueuing torrent deletion jobs.

  This module provides a clean interface for deleting torrents asynchronously.
  The actual job processing is handled by SyncEngine.JobQueue.

  ## Usage

      # Delete a single torrent by rd_id
      DeletionWorker.enqueue("RDID123")

      # Delete multiple torrents
      DeletionWorker.enqueue_batch(["RDID123", "RDID456"])
  """

  @doc """
  Enqueues a deletion job for a torrent by rd_id.

  ## Examples

      iex> DeletionWorker.enqueue("RDID123")
      :ok

  """
  def enqueue(rd_id) when is_binary(rd_id) do
    SyncEngine.JobQueue.enqueue(:delete_torrent, %{rd_id: rd_id})
  end

  @doc """
  Enqueues deletion jobs for multiple torrents by rd_id.

  ## Examples

      iex> DeletionWorker.enqueue_batch(["RDID123", "RDID456"])
      :ok

  """
  def enqueue_batch(rd_ids) when is_list(rd_ids) do
    Enum.each(rd_ids, fn rd_id ->
      enqueue(rd_id)
    end)

    :ok
  end
end
