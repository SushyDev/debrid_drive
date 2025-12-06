defmodule SyncEngine.Services.TorrentVerifier do
  @moduledoc """
  Verifies the integrity of torrents and their files in the VFS.

  This module handles:
  - Checking if torrent files still exist in the VFS
  - Removing orphaned database records
  - Cleaning up torrents with no remaining files
  - Detecting and fixing inconsistencies

  Similar to the Go implementation's `checkFiles()` function.
  """

  require Logger
  alias VFS
  alias VFS.Repo
  alias SyncEngine.Torrents
  alias SyncEngine.Schemas.{Torrent, TorrentFile}

  @doc """
  Verifies all torrents and their files, cleaning up inconsistencies.

  ## Returns
    - `{:ok, %{verified: count, removed_files: count, removed_torrents: count, errors: [errors]}}`
  """
  def verify_all do
    Logger.info("Starting torrent verification")
    start_time = System.monotonic_time(:millisecond)

    torrents = Torrents.list_torrents()

    results = Enum.map(torrents, &verify_torrent/1)

    verified = length(torrents)
    removed_files = Enum.sum(Enum.map(results, fn r -> r.removed_files end))
    removed_torrents = Enum.count(results, fn r -> r.removed_torrent end)
    errors = Enum.flat_map(results, fn r -> r.errors end)

    duration = System.monotonic_time(:millisecond) - start_time

    Logger.info(
      "Verification completed in #{duration}ms: " <>
        "#{verified} torrents verified, #{removed_files} files removed, " <>
        "#{removed_torrents} torrents removed"
    )

    {:ok,
     %{
       verified: verified,
       removed_files: removed_files,
       removed_torrents: removed_torrents,
       errors: errors
     }}
  end

  @doc """
  Verifies a single torrent and its files.

  ## Returns
    - `%{removed_files: count, removed_torrent: boolean, errors: [errors]}`
  """
  def verify_torrent(%Torrent{} = torrent) do
    Logger.debug("Verifying torrent: #{torrent.filename} (#{torrent.rd_id})")

    # First, check if the torrent's VFS node exists
    case VFS.get_node(torrent.node_id) do
      {:ok, _node} ->
        # Node exists, now verify files
        verify_torrent_files(torrent)

      {:error, :not_found} ->
        # Torrent directory is missing, remove the torrent
        Logger.warning(
          "Torrent directory missing for #{torrent.filename}, removing from database"
        )

        case Torrents.delete_torrent(torrent) do
          {:ok, _} ->
            %{removed_files: 0, removed_torrent: true, errors: []}

          {:error, reason} ->
            %{
              removed_files: 0,
              removed_torrent: false,
              errors: [{:delete_torrent_failed, torrent.rd_id, reason}]
            }
        end
    end
  end

  defp verify_torrent_files(%Torrent{} = torrent) do
    files = Torrents.list_torrent_files(torrent.id)

    # Check each file
    file_results = Enum.map(files, &verify_torrent_file/1)

    removed_files = Enum.count(file_results, fn result -> result.removed end)
    file_errors = Enum.flat_map(file_results, fn result -> result.errors end)

    # If all files were removed, delete the torrent
    remaining_files = length(files) - removed_files

    if remaining_files == 0 and length(files) > 0 do
      Logger.info(
        "Torrent #{torrent.filename} has no remaining files, removing torrent and directory"
      )

      case remove_empty_torrent(torrent) do
        :ok ->
          %{removed_files: removed_files, removed_torrent: true, errors: file_errors}

        {:error, reason} ->
          %{
            removed_files: removed_files,
            removed_torrent: false,
            errors: file_errors ++ [{:remove_empty_torrent_failed, torrent.rd_id, reason}]
          }
      end
    else
      %{removed_files: removed_files, removed_torrent: false, errors: file_errors}
    end
  end

  defp verify_torrent_file(%TorrentFile{} = file) do
    case VFS.get_node(file.node_id) do
      {:ok, _node} ->
        # File exists
        %{removed: false, errors: []}

      {:error, :not_found} ->
        # File node is missing, remove from database
        Logger.debug("File node #{file.node_id} missing, removing torrent file record")

        case Torrents.delete_torrent_file(file) do
          {:ok, _} ->
            %{removed: true, errors: []}

          {:error, reason} ->
            %{removed: false, errors: [{:delete_file_failed, file.id, reason}]}
        end
    end
  end

  defp remove_empty_torrent(%Torrent{} = torrent) do
    result = Repo.transaction(fn ->
      # Delete the torrent (will cascade to files)
      case Torrents.delete_torrent(torrent) do
        {:ok, _} ->
          # Also try to remove the VFS directory
          case VFS.remove_by_id(torrent.node_id) do
            {:ok, _} ->
              :ok

            {:error, :not_found} ->
              # Directory already gone, that's fine
              :ok

            {:error, reason} ->
              Logger.warning(
                "Failed to remove VFS directory for torrent #{torrent.rd_id}: #{inspect(reason)}"
              )

              # Still return ok since database was cleaned up
              :ok
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)

    case result do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Verifies a specific torrent by Real Debrid ID.
  """
  def verify_by_rd_id(rd_id) do
    case Torrents.get_torrent_by_rd_id(rd_id) do
      {:ok, torrent} ->
        result = verify_torrent(torrent)
        {:ok, result}

      {:error, :not_found} = error ->
        error
    end
  end
end
