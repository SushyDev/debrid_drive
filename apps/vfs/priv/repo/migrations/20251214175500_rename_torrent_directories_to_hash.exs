defmodule VFS.Repo.Migrations.RenameTorrentDirectoriesToHash do
  @moduledoc """
  Renames torrent directories from rd_id to hash.

  This makes directory names consistent with the new hash-based system,
  where torrents are identified by their immutable hash rather than
  the Real-Debrid ID which can change if a torrent is re-added.
  """
  use Ecto.Migration

  import Ecto.Query
  alias VFS.Repo

  def up do
    # Get all torrents with their directory entries
    torrents_with_dirs =
      from(t in "torrents",
        join: i in "inodes",
        on: t.inode_id == i.inode_id,
        join: de in "directory_entries",
        on: de.inode_id == i.inode_id,
        select: %{
          torrent_id: t.id,
          rd_id: t.rd_id,
          hash: t.hash,
          inode_id: t.inode_id,
          dir_entry_id: de.id,
          current_name: de.name,
          parent_inode_id: de.parent_inode_id
        }
      )
      |> Repo.all()

    # Rename each directory from rd_id to hash
    Enum.each(torrents_with_dirs, fn torrent ->
      if torrent.current_name == torrent.rd_id do
        # Update the directory entry name to use hash
        execute("""
        UPDATE directory_entries
        SET name = '#{torrent.hash}'
        WHERE id = #{torrent.dir_entry_id}
        """)

        IO.puts("Renamed torrent directory: #{torrent.rd_id} -> #{torrent.hash}")
      else
        IO.puts("Skipping torrent #{torrent.rd_id} - directory name '#{torrent.current_name}' doesn't match rd_id")
      end
    end)
  end

  def down do
    # Get all torrents with their directory entries
    torrents_with_dirs =
      from(t in "torrents",
        join: i in "inodes",
        on: t.inode_id == i.inode_id,
        join: de in "directory_entries",
        on: de.inode_id == i.inode_id,
        select: %{
          torrent_id: t.id,
          rd_id: t.rd_id,
          hash: t.hash,
          inode_id: t.inode_id,
          dir_entry_id: de.id,
          current_name: de.name,
          parent_inode_id: de.parent_inode_id
        }
      )
      |> Repo.all()

    # Rename directories back from hash to rd_id
    Enum.each(torrents_with_dirs, fn torrent ->
      if torrent.current_name == torrent.hash do
        # Update the directory entry name back to rd_id
        execute("""
        UPDATE directory_entries
        SET name = '#{torrent.rd_id}'
        WHERE id = #{torrent.dir_entry_id}
        """)

        IO.puts("Renamed torrent directory back: #{torrent.hash} -> #{torrent.rd_id}")
      else
        IO.puts("Skipping torrent #{torrent.rd_id} - directory name '#{torrent.current_name}' doesn't match hash")
      end
    end)
  end
end
