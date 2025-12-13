defmodule SyncEngine.Torrents do
  @moduledoc """
  Context module for managing torrents and their files in the database.
  """

  require Logger

  import Ecto.Query
  alias VFS.Repo
  alias VFS.Node
  alias SyncEngine.Schemas.Torrent
  alias SyncEngine.Schemas.TorrentFile
  alias SyncEngine.Schemas.RejectedTorrent

  @doc """
  Gets all torrents from the database.
  """
  def list_torrents do
    Repo.all(Torrent)
  end

  @doc """
  Gets all torrents with their files preloaded.
  """
  def list_torrents_with_files do
    Torrent
    |> preload(:files)
    |> Repo.all()
  end

  @doc """
  Gets a single torrent by ID.
  """
  def get_torrent(id) do
    case Repo.get(Torrent, id) do
      nil -> {:error, :not_found}
      torrent -> {:ok, torrent}
    end
  end

  @doc """
  Gets a torrent by its Real Debrid ID.
  """
  def get_torrent_by_rd_id(rd_id) do
    case Repo.get_by(Torrent, rd_id: rd_id) do
      nil -> {:error, :not_found}
      torrent -> {:ok, torrent}
    end
  end

  @doc """
  Gets a torrent by its hash.
  """
  def get_torrent_by_hash(hash) do
    case Repo.get_by(Torrent, hash: hash) do
      nil -> {:error, :not_found}
      torrent -> {:ok, torrent}
    end
  end

  @doc """
  Creates a torrent.
  """
  def create_torrent(attrs) do
    %Torrent{}
    |> Torrent.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a torrent.
  """
  def update_torrent(%Torrent{} = torrent, attrs) do
    torrent
    |> Torrent.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a torrent and all its files (via cascade).
  """
  def delete_torrent(%Torrent{} = torrent) do
    Repo.delete(torrent)
  end

  @doc """
  Deletes a torrent by Real Debrid ID.
  """
  def delete_torrent_by_rd_id(rd_id) do
    case get_torrent_by_rd_id(rd_id) do
      {:ok, torrent} -> delete_torrent(torrent)
      error -> error
    end
  end

  @doc """
  Gets all files for a torrent.
  """
  def list_torrent_files(torrent_id) do
    TorrentFile
    |> where([f], f.torrent_id == ^torrent_id)
    |> Repo.all()
  end

  @doc """
  Creates a torrent file.
  """
  def create_torrent_file(attrs) do
    %TorrentFile{}
    |> TorrentFile.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Gets a torrent file by torrent_id and rd_id.
  """
  def get_torrent_file(torrent_id, rd_id) do
    case Repo.get_by(TorrentFile, torrent_id: torrent_id, rd_id: rd_id) do
      nil -> {:error, :not_found}
      file -> {:ok, file}
    end
  end

  @doc """
  Gets a torrent file by node_id.
  """
  def get_torrent_file_by_node_id(node_id) do
    case Repo.get_by(TorrentFile, node_id: node_id) do
      nil -> {:error, :not_found}
      file -> {:ok, file}
    end
  end

  @doc """
  Updates a torrent file using a changeset.
  """
  def update_torrent_file(%Ecto.Changeset{} = changeset) do
    Repo.update(changeset)
  end

  @doc """
  Updates a torrent file with attributes.
  """
  def update_torrent_file(%TorrentFile{} = file, attrs) do
    file
    |> TorrentFile.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a torrent file.
  """
  def delete_torrent_file(%TorrentFile{} = file) do
    Repo.delete(file)
  end

  @doc """
  Returns a map of torrent hashes to torrent records for quick lookup.
  """
  def get_torrents_by_hash do
    list_torrents()
    |> Enum.map(&{&1.hash, &1})
    |> Map.new()
  end

  @doc """
  Returns a map of Real Debrid IDs to torrent records for quick lookup.
  """
  def get_torrents_by_rd_id do
    list_torrents()
    |> Enum.map(&{&1.rd_id, &1})
    |> Map.new()
  end

  # --- Rejected Torrents ---

  @doc """
  Gets all rejected torrents.
  """
  def list_rejected_torrents do
    Repo.all(RejectedTorrent)
  end

  @doc """
  Checks if a torrent is rejected by its Real Debrid ID.
  """
  def torrent_rejected?(rd_id) do
    Repo.exists?(from(r in RejectedTorrent, where: r.rd_id == ^rd_id))
  end

  @doc """
  Gets a rejected torrent by Real Debrid ID.
  """
  def get_rejected_torrent(rd_id) do
    case Repo.get_by(RejectedTorrent, rd_id: rd_id) do
      nil -> {:error, :not_found}
      rejected -> {:ok, rejected}
    end
  end

  @doc """
  Returns a map of Real Debrid IDs to rejected torrent records for quick lookup.
  """
  def get_rejected_torrents_by_rd_id do
    list_rejected_torrents()
    |> Enum.map(&{&1.rd_id, &1})
    |> Map.new()
  end

  @doc """
  Marks a torrent as rejected with a reason.
  """
  def reject_torrent(attrs) do
    attrs
    |> RejectedTorrent.reject_changeset()
    |> Repo.insert()
  end

  @doc """
  Increments the attempt count for a rejected torrent.
  """
  def increment_rejection_attempts(%RejectedTorrent{} = rejected_torrent) do
    rejected_torrent
    |> RejectedTorrent.increment_attempts()
    |> Repo.update()
  end

  @doc """
  Deletes a rejected torrent (for allowing retry).
  """
  def delete_rejected_torrent(%RejectedTorrent{} = rejected_torrent) do
    Repo.delete(rejected_torrent)
  end

  @doc """
  Deletes a rejected torrent by Real Debrid ID.
  """
  def delete_rejected_torrent_by_rd_id(rd_id) do
    case get_rejected_torrent(rd_id) do
      {:ok, rejected} -> delete_rejected_torrent(rejected)
      error -> error
    end
  end

  # --- Deletion Operations ---

  @doc """
  Marks a torrent for deletion.
  Sets deletion_status to "pending_deletion" and records the timestamp.
  """
  def mark_for_deletion(torrent_id) when is_integer(torrent_id) do
    case get_torrent(torrent_id) do
      {:ok, torrent} ->
        torrent
        |> Ecto.Changeset.change(%{
          deletion_status: "pending_deletion",
          deletion_requested_at: DateTime.utc_now() |> DateTime.truncate(:second),
          deletion_attempts: 0
        })
        |> Repo.update()
        |> case do
          {:ok, _updated} -> :ok
          {:error, changeset} -> {:error, changeset}
        end

      {:error, :not_found} ->
        {:error, :torrent_not_found}
    end
  end

  @doc """
  Queues a torrent deletion job.
  Enqueues an Oban job to process the deletion asynchronously.
  """
  def queue_deletion(torrent_id) when is_integer(torrent_id) do
    SyncEngine.Workers.DeletionWorker.enqueue(torrent_id)
  end

  @doc """
  Gets all torrents pending deletion.
  """
  def list_pending_deletions do
    Torrent
    |> where([t], t.deletion_status == "pending_deletion")
    |> Repo.all()
  end

  @doc """
  Gets all torrents with a specific deletion status.
  """
  def list_torrents_with_deletion_status(status) when is_binary(status) do
    Torrent
    |> where([t], t.deletion_status == ^status)
    |> Repo.all()
  end

  @doc """
  Records a deletion attempt for a torrent.
  Increments the attempt counter and updates the last attempted timestamp.
  """
  def record_deletion_attempt(%Torrent{} = torrent, result) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    attrs =
      case result do
        :ok ->
          %{
            deletion_status: "deleted",
            deletion_attempts: torrent.deletion_attempts + 1,
            deletion_last_attempted_at: now
          }

        {:error, reason} ->
          new_status =
            if torrent.deletion_attempts + 1 >= 3 do
              "failed"
            else
              "pending_deletion"
            end

          %{
            deletion_status: new_status,
            deletion_attempts: torrent.deletion_attempts + 1,
            deletion_last_attempted_at: now,
            deletion_error: inspect(reason)
          }
      end

    torrent
    |> Ecto.Changeset.change(attrs)
    |> Repo.update()
  end

  @doc """
  Cleans up a torrent and its associated VFS nodes after successful API deletion.

  This is called by the sync engine after confirming the torrent is deleted from Real-Debrid.

  In the new hardlink-based model (where TorrentFiles are virtual inodes):
  - TorrentFiles are virtual inodes with no associated VFS file nodes
  - Only hardlinks reference virtual inodes via data = "vi:{torrent_file_id}"
  - All hardlinks pointing to deleted virtual inodes must also be deleted

  It removes:
  1. All hard links pointing to the torrent's virtual inodes
  2. All torrent_file records (the virtual inodes themselves)
  3. The torrent record
  4. The parent torrent directory (if empty)
  """
  def cleanup_after_deletion(torrent_id, _opts \\ []) when is_integer(torrent_id) do
    result =
      Repo.transaction(fn ->
        case get_torrent(torrent_id) do
          {:ok, torrent} ->
            # Preload files to find hardlinks pointing to them
            torrent = Repo.preload(torrent, :files)

            # Get the parent directory node_id (if exists)
            parent_node_id = torrent.node_id

            # Delete all hard links pointing to this torrent's virtual inode files
            # (Virtual inodes are being deleted, so hardlinks can't exist without them)
            Enum.each(torrent.files, fn torrent_file ->
              # Find hardlinks pointing to this virtual inode using is_hardlink and hardlink_target_id
              hardlinks =
                Repo.all(
                  from(n in Node,
                    where:
                      n.is_hardlink == true and
                        n.hardlink_target_torrent_file_id == ^torrent_file.id
                  )
                )

              Enum.each(hardlinks, fn link -> VFS.remove_by_id(link.id) end)
            end)

            # Delete all torrent_file records (the virtual inodes)
            from(f in TorrentFile, where: f.torrent_id == ^torrent_id)
            |> Repo.delete_all()

            # Delete the torrent record
            Repo.delete!(torrent)

            # Try to delete the parent directory if it's empty
            if parent_node_id do
              case VFS.get_node(parent_node_id) do
                {:ok, node} ->
                  # Check if directory is empty
                  children = VFS.list_children(node.id)

                  if length(children) == 0 do
                    # Delete empty torrent directory
                    # VFS.remove_by_id returns the deleted node directly, not {:ok, node}
                    try do
                      VFS.remove_by_id(node.id)
                      :ok
                    rescue
                      # Ignore errors, directory might be user-managed
                      _ -> :ok
                    end
                  end

                {:error, :not_found} ->
                  # Node already deleted, that's fine
                  :ok
              end
            end

            :ok

          {:error, :not_found} ->
            # Torrent already deleted, that's fine (idempotent)
            :ok
        end
      end)

    case result do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Batch deletes multiple torrents.
  Marks all torrents for deletion and queues deletion jobs.
  """
  def batch_delete(torrent_ids) when is_list(torrent_ids) do
    # Mark all torrents for deletion first
    Enum.each(torrent_ids, &mark_for_deletion/1)

    # Enqueue all deletion jobs in batch
    SyncEngine.Workers.DeletionWorker.enqueue_batch(torrent_ids)
  end

  # --- Virtual Inode Hardlink Management ---

  @doc """
  Increments the hardlink count for a virtual inode.
  Called when a new hardlink is created to a torrent file.
  """
  def increment_hardlink_count(%TorrentFile{} = torrent_file) do
    torrent_file
    |> Ecto.Changeset.change(%{hardlink_count: torrent_file.hardlink_count + 1})
    |> Repo.update()
  end

  @doc """
  Decrements the hardlink count for a virtual inode.
  Returns {new_count, should_delete_torrent}.

  should_delete_torrent is true only when ALL files in the torrent have hardlink_count == 0.
  This ensures we only delete the torrent from Remote Debrid when no hardlinks exist for any of its files.

  Called when a hardlink is unlinked by the user.

  Uses a database transaction to ensure atomic checking of all files in the torrent,
  preventing race conditions where concurrent decrements could lead to incorrect
  deletion decisions.
  """
  def decrement_hardlink_count(%TorrentFile{} = torrent_file) do
    Repo.transaction(fn ->
      # Reload and lock the row for update within the transaction
      locked_file = Repo.get!(TorrentFile, torrent_file.id, lock: "FOR UPDATE")

      new_count = max(0, locked_file.hardlink_count - 1)

      changeset = Ecto.Changeset.change(locked_file, %{hardlink_count: new_count})

      case Repo.update(changeset) do
        {:ok, updated} ->
          # Now check if ALL files in the torrent have hardlink_count == 0
          # This query is atomic within the transaction
          query =
            from(tf in TorrentFile,
              where: tf.torrent_id == ^updated.torrent_id,
              select: tf.hardlink_count
            )

          counts = Repo.all(query)
          should_delete = Enum.all?(counts, &(&1 == 0))

          {new_count, should_delete}

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {new_count, should_delete}} -> {:ok, {new_count, should_delete}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Verifies that a virtual inode's hardlink count matches actual hardlinks in VFS.
  Auto-corrects if mismatch is found.
  """
  def verify_hardlink_count(%TorrentFile{} = torrent_file) do
    actual_count = VFS.count_hardlinks_to_virtual_inode(torrent_file.id)

    if actual_count != torrent_file.hardlink_count do
      Logger.warning(
        "Hardlink count mismatch for torrent_file #{torrent_file.id}: " <>
          "expected #{torrent_file.hardlink_count}, got #{actual_count}"
      )

      # Auto-correct
      update_torrent_file(torrent_file, %{hardlink_count: actual_count})
    else
      {:ok, torrent_file}
    end
  end

  @doc """
  Gets a torrent file by ID (for virtual inode lookup).
  """
  def get_torrent_file_by_id(id) do
    case Repo.get(TorrentFile, id) do
      nil -> {:error, :not_found}
      file -> {:ok, file}
    end
  end
end
