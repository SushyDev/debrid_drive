defmodule SyncEngine.Torrents do
  @moduledoc """
  Context module for managing torrents and their files in the database.
  """

  require Logger

  import Ecto.Query
  alias VFS.Repo
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
    case Repo.get_by(Torrent, real_debrid_torrent_id: rd_id) do
      nil -> {:error, :not_found}
      torrent -> {:ok, torrent}
    end
  end

  @doc """
  Gets a torrent by its hash.
  """
  def get_torrent_by_hash(hash) do
    case Repo.get_by(Torrent, real_debrid_torrent_hash: hash) do
      nil -> {:error, :not_found}
      torrent -> {:ok, torrent}
    end
  end

  @doc """
  Creates a torrent, or updates if it already exists (based on rd_id).

  Note: Multiple torrents can have the same hash (different rd_ids).
  rd_id is unique per torrent instance.

  On conflict (duplicate rd_id), updates all fields with the latest data
  from Real-Debrid.
  """
  def create_torrent(attrs) do
    changeset =
      %Torrent{}
      |> Torrent.changeset(attrs)

    # Upsert strategy: if torrent with this rd_id exists, update it with latest data
    # The unique constraint is on :rd_id
    Repo.insert(changeset,
      on_conflict: :replace_all_except_primary_key,
      conflict_target: :real_debrid_torrent_id
    )
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
  Deletes a torrent and all its files.

  Files are automatically deleted via database trigger (cascade).
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
  Gets all files for a torrent by hash.
  """
  def list_torrent_files(torrent_hash) when is_binary(torrent_hash) do
    TorrentFile
    |> where([f], f.real_debrid_torrent_hash == ^torrent_hash)
    |> Repo.all()
  end

  @doc """
  Creates a torrent file with merge and conditional upsert logic.

  Uses a merge strategy: attempts to insert, and on conflict (same torrent_hash + torrent_rd_id + rd_id),
  merges the data by updating only specific fields while preserving hardlink_count.
  This prevents losing hardlink tracking when the same torrent is re-added to Real-Debrid.
  """
  def create_torrent_file(attrs) do
    changeset =
      %TorrentFile{}
      |> TorrentFile.changeset(attrs)

    # Merge strategy: on conflict, upsert with selected fields
    # The unique constraint is on [:torrent_hash, :torrent_rd_id, :rd_id]
    # Preserve hardlink_count to avoid resetting reference tracking
    Repo.insert(changeset,
      on_conflict: {:replace, [:path, :bytes, :selected, :link, :updated_at]},
      conflict_target: [:real_debrid_torrent_hash, :real_debrid_torrent_id, :real_debrid_torrent_file_id]
    )
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
    |> Enum.map(&{&1.real_debrid_torrent_hash, &1})
    |> Map.new()
  end

  @doc """
  Returns a map of Real Debrid IDs to torrent records for quick lookup.
  """
  def get_torrents_by_rd_id do
    list_torrents()
    |> Enum.map(&{&1.real_debrid_torrent_id, &1})
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
    RejectedTorrent
    |> where([rejected_torrent], rejected_torrent.real_debrid_torrent_id == ^rd_id)
    |> Repo.exists?()
  end

  @doc """
  Gets a rejected torrent by Real Debrid ID.
  """
  def get_rejected_torrent(rd_id) do
    case Repo.get_by(RejectedTorrent, real_debrid_torrent_id: rd_id) do
      nil -> {:error, :not_found}
      rejected -> {:ok, rejected}
    end
  end

  @doc """
  Returns a map of Real Debrid IDs to rejected torrent records for quick lookup.
  """
  def get_rejected_torrents_by_rd_id do
    list_rejected_torrents()
    |> Enum.map(&{&1.real_debrid_torrent_id, &1})
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
  Marks a torrent for deletion by Real Debrid ID.
  Sets deletion_status to "pending_deletion" and records the timestamp.
  """
  def mark_for_deletion(rd_id) when is_binary(rd_id) do
    case get_torrent_by_rd_id(rd_id) do
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
        {:error, :not_found}
    end
  end

  @doc """
  Queues a torrent deletion job by Real Debrid ID.
  Enqueues a deletion worker job to process the deletion asynchronously.
  """
  def queue_deletion(rd_id) when is_binary(rd_id) do
    SyncEngine.Workers.DeletionWorker.enqueue(rd_id)
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
  Uses rd_id to identify the specific torrent instance to delete.

  This is the correct function to use for deletion, as it ensures only files
  belonging to the specific torrent instance (rd_id) are removed, even if
  multiple torrents with the same hash exist.

  It removes:
  1. All hard links pointing to this torrent instance's virtual inodes
  2. All torrent_file records belonging to this torrent instance
  3. The torrent record
  4. The parent torrent directory (if empty)
  """
  def cleanup_after_deletion_by_rd_id(rd_id, _opts \\ []) when is_binary(rd_id) do
    Repo.transact(fn ->
      case get_torrent_by_rd_id(rd_id) do
        {:ok, torrent} ->
          # Get the parent directory inode_id (if exists)
          parent_inode_id = torrent.inode_id

          # Get all torrent files belonging to THIS SPECIFIC torrent instance
          torrent_files =
            SyncEngine.Queries.TorrentFileQueries.get_files_for_torrent(
              torrent.real_debrid_torrent_hash,
              torrent.real_debrid_torrent_id
            )

          # Handle directory entries (hardlinks) pointing to this torrent's files
          # With merge logic, files might be shared between multiple torrent instances
          Enum.each(torrent_files, fn torrent_file ->
            cleanup_torrent_file_inodes(torrent_file, torrent)
          end)

          # Delete all torrent_file records belonging to THIS SPECIFIC torrent instance
          TorrentFile
          |> where([f], f.real_debrid_torrent_hash == ^torrent.real_debrid_torrent_hash)
          |> where([f], f.real_debrid_torrent_id == ^torrent.real_debrid_torrent_id)
          |> Repo.delete_all()

          # Nullify the foreign key before attempting any inode deletion
          # This is required due to foreign key constraint with on_delete: :restrict
          torrent =
            torrent
            |> Ecto.Changeset.change(%{inode_id: nil})
            |> Repo.update!()

          # Try to delete the parent directory if it's empty
          if parent_inode_id do
            case VFS.get_node(parent_inode_id) do
              {:ok, inode} ->
                # Check if directory is empty
                children = VFS.list_children(inode.inode_id)

                if length(children) == 0 do
                  # Delete empty torrent directory
                  # Need to find the directory entry for this inode to delete it
                  case VFS.DirectoryEntry
                       |> where([directory_entry], directory_entry.inode_id == ^inode.inode_id)
                       |> limit(1)
                       |> Repo.one() do
                    %VFS.DirectoryEntry{} = entry ->
                      try do
                        VFS.remove(entry.parent_inode_id, entry.name)
                        :ok
                      rescue
                        # Ignore errors, directory might be user-managed
                        _ -> :ok
                      end

                    nil ->
                      :ok
                  end
                end

              {:error, :not_found} ->
                # Inode already deleted, that's fine
                :ok
            end
          end

          # Delete the torrent record (inode_id is now NULL, so safe to delete)
          Repo.delete!(torrent)

          {:ok, :ok}

        {:error, :not_found} ->
          # Torrent already deleted, that's fine (idempotent)
          {:ok, :ok}
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Batch deletes multiple torrents by Real Debrid ID.
  Marks all torrents for deletion and queues deletion jobs.
  """
  def batch_delete(rd_ids) when is_list(rd_ids) do
    # Mark all torrents for deletion first
    Enum.each(rd_ids, &mark_for_deletion/1)

    # Enqueue all deletion jobs in batch
    SyncEngine.Workers.DeletionWorker.enqueue_batch(rd_ids)
  end

  # --- Virtual Inode Hardlink Management ---

  @doc """
  Increments the hardlink count for a virtual inode.
  Called when a new hardlink is created to a torrent file.

  Uses row-level locking to prevent lost increments in concurrent scenarios
  where multiple inodes might be updated to point to the same replacement file.
  """
  def increment_hardlink_count(%TorrentFile{} = torrent_file) do
    Repo.transact(fn ->
      # Reload and lock the row for update within the transaction
      locked_file = Repo.get!(TorrentFile, torrent_file.id, lock: "FOR UPDATE")

      changeset = Ecto.Changeset.change(locked_file, %{hardlink_count: locked_file.hardlink_count + 1})

      case Repo.update(changeset) do
        {:ok, updated} -> {:ok, updated}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @doc """
  Decrements the hardlink count for a virtual inode.
  Returns {new_count, should_delete_torrent, torrent_rd_id}.

  should_delete_torrent is true only when ALL files in this specific torrent instance
  have hardlink_count == 0. This ensures we only delete the torrent from Real Debrid 
  when no hardlinks exist for any of its files.

  Called when a hardlink is unlinked by the user.

  Uses a database transaction to ensure atomic checking of all files in the torrent,
  preventing race conditions where concurrent decrements could lead to incorrect
  deletion decisions.
  """
  def decrement_hardlink_count(%TorrentFile{} = torrent_file) do
    Repo.transact(fn ->
      # Reload and lock the row for update within the transaction
      locked_file = Repo.get!(TorrentFile, torrent_file.id, lock: "FOR UPDATE")

      new_count = max(0, locked_file.hardlink_count - 1)

      changeset = Ecto.Changeset.change(locked_file, %{hardlink_count: new_count})

      case Repo.update(changeset) do
        {:ok, updated} ->
          # Now check if ALL files in THIS SPECIFIC torrent instance have hardlink_count == 0
          # Filter by both hash AND torrent_rd_id to only check files from this torrent instance
          query =
            TorrentFile
            |> where([torrent_file], torrent_file.real_debrid_torrent_hash == ^updated.real_debrid_torrent_hash)
            |> where([torrent_file], torrent_file.real_debrid_torrent_id == ^updated.real_debrid_torrent_id)
            |> select([torrent_file], torrent_file.hardlink_count)

          counts = Repo.all(query)
          should_delete = Enum.all?(counts, &(&1 == 0))

          # Return the torrent_rd_id so caller knows which torrent to delete
          {:ok, {new_count, should_delete, updated.real_debrid_torrent_id}}

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {new_count, should_delete, torrent_rd_id}} ->
        {:ok, {new_count, should_delete, torrent_rd_id}}

      {:error, reason} ->
        {:error, reason}
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

  # --- Private Helper Functions ---

  # Cleans up VFS inodes for a torrent_file being deleted
  defp cleanup_torrent_file_inodes(torrent_file, torrent) do
    # Find all inodes pointing to this virtual_inode_id
    inodes =
      VFS.Inode
      |> where([inode], inode.virtual_inode_type == "torrent_file")
      |> where([inode], inode.virtual_inode_id == ^torrent_file.id)
      |> Repo.all()

    # For each inode, check if there are other torrent_files with same hash + path
    Enum.each(inodes, fn inode ->
      handle_inode_cleanup(inode, torrent_file, torrent)
    end)
  end

  # Handles cleanup for a single inode - either delete it or update to next version
  defp handle_inode_cleanup(inode, torrent_file, torrent) do
    # Find other torrent_files (excluding the one being deleted) with same hash + path
    other_files =
      SyncEngine.Queries.TorrentFileQueries.find_others_for_path(
        torrent_file.real_debrid_torrent_hash,
        torrent_file.path,
        torrent.real_debrid_torrent_id
      )

    case other_files do
      [] ->
        # No other files - safe to delete the inode (and its directory entries)
        delete_inode_and_entries(inode)

      [most_recent | _] ->
        # Other files exist - update inode to point to most recent
        update_inode_to_replacement(inode, most_recent)
    end
  end

  # Deletes a VFS inode and all its directory entries
  defp delete_inode_and_entries(inode) do
    # Find all directory entries for this inode
    entries =
      VFS.DirectoryEntry
      |> where([de], de.inode_id == ^inode.inode_id)
      |> Repo.all()

    # Delete each entry
    Enum.each(entries, fn entry ->
      case VFS.remove(entry.parent_inode_id, entry.name) do
        :ok -> :ok
        {:error, _} -> :ok
      end
    end)
  end

  # Updates a VFS inode to point to a replacement torrent_file
  # Also increments the hardlink_count of the replacement file
  defp update_inode_to_replacement(inode, replacement_file) do
    case SyncEngine.Services.InodeManager.update_inode_to_file(inode, replacement_file) do
      {:ok, _} ->
        # Increment hardlink_count on the replacement file since inode now points to it
        increment_hardlink_count(replacement_file)
        :ok

      {:error, _} ->
        :ok
    end
  end
end
