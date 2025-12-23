defmodule SyncEngine.Queries.TorrentFileQueries do
  @moduledoc """
  Shared query functions for torrent_files table.

  Provides reusable queries for finding, filtering, and analyzing torrent files.
  """

  import Ecto.Query
  alias SyncEngine.Schemas.{TorrentFile, Torrent}
  alias VFS.Repo

  @doc """
  Finds the most recent torrent_file for a given hash and path.

  Orders by torrent.added (Real-Debrid timestamp) first, then by
  torrent_file.inserted_at as a tiebreaker.

  Returns nil if no matching files exist.
  """
  def find_most_recent(hash, path) do
    TorrentFile
    |> where([f], f.torrent_hash == ^hash)
    |> where([f], f.path == ^path)
    |> join(:inner, [f], t in Torrent, on: f.torrent_rd_id == t.rd_id)
    |> order_by([f, t], desc: t.added, desc: f.inserted_at)
    |> limit(1)
    |> select([f, _t], f)
    |> Repo.one()
  end

  @doc """
  Finds all torrent_files with the given hash and path, excluding a specific torrent_rd_id.

  Useful for finding "other instances" of the same file when handling deletions.
  Returns results ordered by most recent first.
  """
  def find_others_for_path(hash, path, excluding_rd_id) do
    TorrentFile
    |> where([f], f.torrent_hash == ^hash)
    |> where([f], f.path == ^path)
    |> where([f], f.torrent_rd_id != ^excluding_rd_id)
    |> join(:inner, [f], t in Torrent, on: f.torrent_rd_id == t.rd_id)
    |> order_by([f, t], desc: t.added, desc: f.inserted_at)
    |> select([f, _t], f)
    |> Repo.all()
  end

  @doc """
  Checks if all files in a torrent instance have zero hardlinks.

  This indicates that all user-visible references to the torrent's files
  have been removed, and the torrent can be safely deleted from Real-Debrid.
  """
  def all_hardlinks_zero?(hash, torrent_rd_id) do
    TorrentFile
    |> where([f], f.torrent_hash == ^hash)
    |> where([f], f.torrent_rd_id == ^torrent_rd_id)
    |> select([f], f.hardlink_count)
    |> Repo.all()
    |> Enum.all?(&(&1 == 0))
  end

  @doc """
  Gets all torrent_files for a specific torrent instance (by hash and rd_id).
  """
  def get_files_for_torrent(hash, torrent_rd_id) do
    TorrentFile
    |> where([f], f.torrent_hash == ^hash)
    |> where([f], f.torrent_rd_id == ^torrent_rd_id)
    |> Repo.all()
  end
end
