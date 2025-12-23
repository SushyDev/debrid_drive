defmodule SyncEngine.Services.TorrentSync do
  @moduledoc """
  Synchronizes Real Debrid torrents with the local database and VFS.

  This module handles:
  - Detecting new torrents and adding them to the database
  - Detecting removed torrents and cleaning them up (cascades to files and VFS nodes)
  - Creating VFS directory structure for torrents and their files
  - Tracking and skipping rejected torrents
  - Configurable torrent directory naming
  """

  require Logger
  alias VFS
  alias VFS.Repo

  # Error types that should result in permanent rejection
  @rejection_errors [
    :file_link_mismatch,
    :invalid_torrent_data,
    :no_selected_files
  ]

  @doc """
  Synchronizes Real Debrid torrents with the database.

  ## Parameters
    - `client` - Real Debrid API client
    - `opts` - Options:
      - `:torrents_root_id` - VFS node ID where torrents should be stored (required)
      - `:verify` - Whether to run file verification after sync (default: true)

  ## Returns
    - `{:ok, %{added: count, removed: count, skipped: count, errors: [errors], verification: result}}`
    - `{:error, reason}`
  """
  def sync(client, opts \\ []) when not is_nil(client) do
    torrents_root_id = Keyword.fetch!(opts, :torrents_root_id)
    verify = Keyword.get(opts, :verify, true)

    with {:ok, rd_torrents} <- fetch_rd_torrents(client),
         {:ok, {db_torrents, rejected_torrents}} <- fetch_db_torrents() do
      # Compare and sync
      result =
        perform_sync(
          client,
          rd_torrents,
          db_torrents,
          rejected_torrents,
          torrents_root_id
        )

      # Run verification if requested
      result =
        if verify do
          {:ok, verification} = SyncEngine.Services.TorrentVerifier.verify_all()
          Map.put(result, :verification, verification)
        else
          result
        end

      Logger.info(
        "TorrentSync completed: #{result.added} added, #{result.removed} removed, " <>
          "#{result.skipped} skipped, #{length(result.errors)} errors"
      )

      {:ok, result}
    end
  end

  # --- Private Functions ---

  defp fetch_rd_torrents(client) when not is_nil(client) do
    result = RealDebrid.Api.Torrents.get_all(client)

    case result do
      {:ok, torrents} when is_list(torrents) ->
        # Filter to only include downloaded/completed torrents
        status_filter = fn %{status: status} -> status in ["downloaded", "seeding"] end
        completed = Enum.filter(torrents, status_filter)

        Logger.info("Fetched #{length(completed)} completed torrents (#{length(torrents)} total)")
        {:ok, completed}

      {:error, reason} = error ->
        Logger.error("Failed to fetch Real Debrid torrents: #{inspect(reason)}")
        error
    end
  end

  defp fetch_db_torrents do
    torrents = SyncEngine.Torrents.get_torrents_by_rd_id()
    rejected = SyncEngine.Torrents.get_rejected_torrents_by_rd_id()
    {:ok, {torrents, rejected}}
  end

  defp perform_sync(
         client,
         rd_torrents,
         db_torrents,
         rejected_torrents,
         torrents_root_id
       ) do
    # Create maps for efficient lookup
    rd_map = Map.new(rd_torrents, fn torrent -> {torrent.id, torrent} end)

    # With new schema: multiple torrents can have same hash with different rd_ids
    # No merge needed - just add any rd_id not already in DB
    to_add =
      Map.keys(rd_map)
      |> Enum.reject(fn rd_id -> Map.has_key?(db_torrents, rd_id) end)
      |> Enum.reject(fn rd_id -> Map.has_key?(rejected_torrents, rd_id) end)

    # Find torrents to remove (in DB but not in RD)
    to_remove = Map.keys(db_torrents) -- Map.keys(rd_map)

    # Log rejected torrents that are being skipped
    skipped_count =
      Enum.count(Map.keys(rd_map), fn rd_id ->
        Map.has_key?(rejected_torrents, rd_id)
      end)

    if skipped_count > 0 do
      Logger.info("Skipping #{skipped_count} rejected torrents")
    end

    # Add new torrents
    add_results =
      Enum.map(to_add, fn rd_id ->
        add_torrent(client, Map.get(rd_map, rd_id), torrents_root_id)
      end)

    added = Enum.count(add_results, &match?({:ok, _}, &1))
    add_errors = Enum.filter(add_results, &match?({:error, _}, &1))

    # Remove deleted torrents
    remove_results =
      Enum.map(to_remove, fn rd_id ->
        remove_torrent(Map.get(db_torrents, rd_id))
      end)

    removed = Enum.count(remove_results, &match?({:ok, _}, &1))
    remove_errors = Enum.filter(remove_results, &match?({:error, _}, &1))

    %{
      added: added,
      removed: removed,
      skipped: skipped_count,
      errors: add_errors ++ remove_errors
    }
  end

  defp add_torrent(client, rd_torrent, torrents_root_id) do
    Logger.info("Adding torrent: #{rd_torrent.filename} (#{rd_torrent.id})")

    # Fetch detailed torrent info BEFORE starting transaction
    # This prevents database timeouts from slow API calls
    with {:ok, torrent_info} <- RealDebrid.Api.TorrentInfo.get(client, rd_torrent.id),
         # Validate torrent before starting transaction
         :ok <- validate_torrent(torrent_info) do
      # Now run the database transaction with pre-fetched data
      result =
        Repo.transact(fn ->
          # 1. Create VFS directory node for the torrent (or get existing)
          dir_name = format_torrent_directory_name(rd_torrent)

          torrent_node_result =
            case VFS.lookup(torrents_root_id, dir_name) do
              {:ok, existing_node} ->
                Logger.debug("Reusing existing directory for torrent #{rd_torrent.id}: #{dir_name}")
                {:ok, existing_node}

              {:error, :not_found} ->
                VFS.create_directory(torrents_root_id, dir_name)
            end

          with {:ok, torrent_node} <- torrent_node_result,
               # 2. Create torrent record
               {:ok, torrent} <-
                 SyncEngine.Torrents.create_torrent(%{
                   rd_id: rd_torrent.id,
                   filename: rd_torrent.filename,
                   hash: rd_torrent.hash,
                   bytes: rd_torrent.bytes,
                   host: rd_torrent.host,
                   split: rd_torrent.split,
                   progress: rd_torrent.progress,
                   status: rd_torrent.status,
                   added: rd_torrent.added,
                   ended: rd_torrent.ended,
                   speed: rd_torrent.speed,
                   seeders: rd_torrent.seeders,
                   inode_id: torrent_node.inode_id
                 }),
               # 3. Add files (using pre-fetched torrent_info)
               {:ok, _files} <-
                 add_torrent_files(torrent, torrent_node, torrent_info.files, torrent_info.links) do
            {:ok, torrent}
          else
            {:error, reason} = error ->
              Logger.error("Failed to add torrent #{rd_torrent.id}: #{inspect(reason)}")

              # Check if this error should result in rejection
              if should_reject?(reason) do
                reject_torrent_with_reason(rd_torrent, reason)
              end

              Repo.rollback(error)
          end
        end)

      result
    else
      {:error, reason} = error ->
        Logger.error("Failed to fetch torrent info for #{rd_torrent.id}: #{inspect(reason)}")

        # Check if this error should result in rejection
        if should_reject?(reason) do
          reject_torrent_with_reason(rd_torrent, reason)
        end

        error
    end
  end

  defp validate_torrent(torrent_info) do
    selected_files = Enum.filter(torrent_info.files, fn file -> file.selected == 1 end)

    cond do
      length(selected_files) == 0 -> {:error, :no_selected_files}
      length(selected_files) > length(torrent_info.links) -> {:error, :file_link_mismatch}
      true -> :ok
    end
  end

  defp should_reject?(reason) when reason in @rejection_errors, do: true
  defp should_reject?(_), do: false

  defp reject_torrent_with_reason(rd_torrent, reason) do
    Logger.warning("Rejecting torrent #{rd_torrent.id}: #{inspect(reason)}")

    SyncEngine.Torrents.reject_torrent(%{
      rd_id: rd_torrent.id,
      filename: rd_torrent.filename,
      hash: rd_torrent.hash,
      reason: Atom.to_string(reason),
      error_details: "Torrent failed validation: #{inspect(reason)}"
    })
  end

  defp add_torrent_files(torrent, torrent_node, rd_files, links) do
    # Filter to only selected files
    selected_files = Enum.filter(rd_files, fn file -> file.selected == 1 end)

    # Pair each file with its corresponding link by index
    files_with_links = Enum.zip(selected_files, links)

    results =
      Enum.map(files_with_links, fn {rd_file, link} ->
        add_torrent_file(torrent, torrent_node, rd_file, link)
      end)

    # Check if any failed
    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, results}
      error -> error
    end
  end

  defp add_torrent_file(torrent, torrent_node, rd_file, link) do
    # Parse the path and create directory structure
    # Strip leading "/" from RD API path (e.g., "/file.mkv" -> "file.mkv")
    normalized_path = String.trim_leading(rd_file.path, "/")
    path_parts = Path.split(normalized_path)
    filename = List.last(path_parts)
    sanitized_filename = sanitize_filename(filename)
    dir_parts = Enum.slice(path_parts, 0..-2//1)

    # Create directory structure if needed
    with {:ok, parent_node} <- ensure_directory_structure(torrent_node.inode_id, dir_parts) do
      # Check if a file with this name already exists in this directory
      case VFS.lookup(parent_node, sanitized_filename) do
        {:ok, existing_inode} ->
          # File already exists - merge and upsert behavior
          handle_existing_file(
            torrent,
            parent_node,
            sanitized_filename,
            existing_inode,
            rd_file,
            link
          )

        {:error, :not_found} ->
          # File doesn't exist - create new
          create_new_file(torrent, parent_node, sanitized_filename, rd_file, link)
      end
    else
      error -> error
    end
  end

  defp create_new_file(torrent, parent_node, sanitized_filename, rd_file, link) do
    # Create virtual inode first (without VFS node)
    with {:ok, virtual_inode} <-
           SyncEngine.Torrents.create_torrent_file(%{
             rd_id: rd_file.id,
             path: rd_file.path,
             bytes: rd_file.bytes,
             selected: rd_file.selected,
             link: link,
             torrent_hash: torrent.hash,
             torrent_rd_id: torrent.rd_id,
             node_id: nil,
             hardlink_count: 1
           }),
         # Create hardlink to virtual inode (instead of source file)
         {:ok, _hardlink_node} <-
           VFS.create_hardlink_to_virtual_inode(
             parent_node,
             sanitized_filename,
             virtual_inode.id,
             size: rd_file.bytes
           ) do
      {:ok, virtual_inode}
    else
      error -> error
    end
  end

  defp handle_existing_file(
         torrent,
         _parent_node,
         _sanitized_filename,
         existing_inode,
         rd_file,
         link
       ) do
    # File already exists - this is the merge + upsert case
    # Get the old torrent_file that this inode currently points to (if any)
    old_torrent_file_id = existing_inode.virtual_inode_id

    # Create the new torrent_file record for this torrent instance
    with {:ok, new_virtual_inode} <-
           SyncEngine.Torrents.create_torrent_file(%{
             rd_id: rd_file.id,
             path: rd_file.path,
             bytes: rd_file.bytes,
             selected: rd_file.selected,
             link: link,
             torrent_hash: torrent.hash,
             torrent_rd_id: torrent.rd_id,
             node_id: nil,
             hardlink_count: 1
           }),
         # Update the existing VFS inode to point to the most recent torrent_file
         {:ok, updated_inode} <-
           SyncEngine.Services.InodeManager.update_to_most_recent(
             existing_inode,
             torrent.hash,
             rd_file.path
           ) do
      # Decrement hardlink_count on the old torrent_file if it changed
      if old_torrent_file_id && old_torrent_file_id != updated_inode.virtual_inode_id do
        case SyncEngine.Torrents.get_torrent_file_by_id(old_torrent_file_id) do
          {:ok, old_file} ->
            SyncEngine.Torrents.decrement_hardlink_count(old_file)

          {:error, :not_found} ->
            # Old file already deleted, nothing to decrement
            :ok
        end
      end

      {:ok, new_virtual_inode}
    else
      error -> error
    end
  end

  defp ensure_directory_structure(parent_id, []), do: {:ok, parent_id}

  defp ensure_directory_structure(parent_id, [dir_name | rest]) do
    sanitized_name = sanitize_filename(dir_name)

    # Try to find existing directory
    case VFS.lookup(parent_id, sanitized_name) do
      {:ok, node} ->
        ensure_directory_structure(node.inode_id, rest)

      {:error, :not_found} ->
        # Create new directory
        case VFS.create_directory(parent_id, sanitized_name) do
          {:ok, node} -> ensure_directory_structure(node.inode_id, rest)
          error -> error
        end
    end
  end

  defp remove_torrent(db_torrent) do
    Logger.info("Removing torrent: #{db_torrent.filename} (#{db_torrent.rd_id})")

    # Delete the torrent (cascade will handle files and VFS nodes)
    with {:ok, _} <- SyncEngine.Torrents.delete_torrent(db_torrent) do
      # Also delete the VFS node for the torrent directory with cascade, if it exists
      if db_torrent.inode_id do
        try do
          VFS.remove_by_id(db_torrent.inode_id, cascade: true)
          {:ok, db_torrent}
        rescue
          error ->
            Logger.error("Failed to remove VFS node for torrent #{db_torrent.rd_id}: #{inspect(error)}")

            {:error, error}
        end
      else
        {:ok, db_torrent}
      end
    else
      error ->
        Logger.error("Failed to remove torrent #{db_torrent.rd_id}: #{inspect(error)}")
        error
    end
  end

  # Format torrent directory name - use hash for consistency and regeneration
  defp format_torrent_directory_name(rd_torrent) do
    rd_torrent.hash
  end

  # Sanitize filename to be safe for filesystem
  defp sanitize_filename(filename) do
    filename
    |> String.replace(~r/[\/\\]/, "_")
    |> String.replace(~r/[\x00-\x1F\x7F]/, "")
    |> String.trim()
  end

  @doc """
  Reconciles local deletion status with the Real-Debrid API.

  Compares torrents that are marked for deletion locally with the current
  list of torrents from the API. If a torrent is marked for deletion but
  no longer exists in the API, it cleans up the local records.

  ## Parameters
    - `api_torrent_ids` - List of torrent IDs currently active in Real-Debrid API

  ## Returns
    - `{:ok, count}` where count is the number of torrents cleaned up
  """
  def reconcile_deletions(api_torrent_ids) when is_list(api_torrent_ids) do
    api_ids_set = MapSet.new(api_torrent_ids)

    # Find torrents marked for deletion
    pending_deletions = SyncEngine.Torrents.list_pending_deletions()

    # Clean up torrents that are gone from the API
    results =
      Enum.map(pending_deletions, fn torrent ->
        if not MapSet.member?(api_ids_set, torrent.rd_id) do
          # Torrent is gone from API, clean it up locally
          Logger.info("Reconciling deletion for torrent #{torrent.rd_id} - already gone from API")
          SyncEngine.Torrents.cleanup_after_deletion_by_rd_id(torrent.rd_id)
        else
          :skip
        end
      end)

    cleaned_count = Enum.count(results, &match?(:ok, &1))
    {:ok, cleaned_count}
  end

  @doc """
  Retries failed deletion attempts for torrents.

  Finds torrents with deletion_status = "failed" and retries deletion
  up to 3 times. After 3 failed attempts, the torrent remains in
  failed state and requires manual intervention.

  ## Parameters
    - `client`: RealDebrid client for API calls

  ## Returns
    - `{:ok, %{retried: count, succeeded: count, still_failed: count}}`
  """
  def retry_failed_deletions(client) do
    # Get all torrents with failed deletion status
    failed_torrents =
      SyncEngine.Torrents.list_torrents_with_deletion_status("failed")
      |> Enum.filter(fn t -> t.deletion_attempts < 3 end)

    results =
      Enum.map(failed_torrents, fn torrent ->
        Logger.info("Retrying deletion for torrent #{torrent.rd_id} (attempt #{torrent.deletion_attempts + 1}/3)")

        # Attempt deletion
        result = RealDebrid.Api.Delete.delete(client, torrent.rd_id)

        case result do
          :ok ->
            Logger.info("Retry successful for torrent #{torrent.rd_id}")
            SyncEngine.Torrents.cleanup_after_deletion_by_rd_id(torrent.rd_id)
            {:success, torrent.hash}

          {:error, "Not found"} ->
            # Already deleted from API, just cleanup
            Logger.info("Torrent #{torrent.rd_id} already deleted, cleaning up")
            SyncEngine.Torrents.cleanup_after_deletion_by_rd_id(torrent.rd_id)
            {:success, torrent.hash}

          {:error, reason} ->
            Logger.warning("Retry failed for torrent #{torrent.rd_id}: #{inspect(reason)}")
            SyncEngine.Torrents.record_deletion_attempt(torrent, {:error, reason})
            {:failed, torrent.hash, reason}
        end
      end)

    succeeded = Enum.count(results, &match?({:success, _}, &1))
    failed = Enum.count(results, &match?({:failed, _, _}, &1))

    {:ok, %{retried: length(failed_torrents), succeeded: succeeded, still_failed: failed}}
  end

  @doc """
  Processes pending deletion requests by calling the Real-Debrid API.

  Finds all torrents with deletion_status = "pending_deletion" and
  attempts to delete them via the API. Updates status based on results.

  ## Parameters
    - `client` - Real Debrid API client

  ## Returns
    - `{:ok, %{processed: count, succeeded: count, failed: count}}`
  """
  def process_pending_deletions(client) do
    pending = SyncEngine.Torrents.list_pending_deletions()

    results =
      Enum.map(pending, fn torrent ->
        Logger.info("Processing deletion for torrent #{torrent.rd_id}")

        case RealDebrid.Api.Delete.delete(client, torrent.rd_id) do
          :ok ->
            # Deletion succeeded, clean up local records
            SyncEngine.Torrents.cleanup_after_deletion_by_rd_id(torrent.rd_id)
            {:ok, torrent.hash}

          {:error, reason} ->
            # Deletion failed, record the attempt
            SyncEngine.Torrents.record_deletion_attempt(torrent, {:error, reason})
            {:error, {torrent.hash, reason}}
        end
      end)

    succeeded = Enum.count(results, &match?({:ok, _}, &1))
    failed = Enum.count(results, &match?({:error, _}, &1))

    {:ok, %{processed: length(pending), succeeded: succeeded, failed: failed}}
  end
end
