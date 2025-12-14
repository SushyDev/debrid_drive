defmodule VFS.Repo.Migrations.UseTorrentHashForFilesAndDirectories do
  @moduledoc """
  Migration to use torrent hash instead of torrent ID for binding torrent files
  and rename torrent directories to use hash.

  This makes the system more resilient to torrent ID changes when torrents are
  removed and re-added to Real-Debrid, since the hash remains constant.

  Changes:
  1. Recreate torrent_files table with torrent_hash instead of torrent_id
  2. Rename torrent directories from rd_id to hash
  3. Preserve all existing data during the migration
  """
  use Ecto.Migration

  import Ecto.Query
  alias VFS.Repo

  def up do
    # ============================================================================
    # PART 1: Update torrent_files table to use torrent_hash
    # ============================================================================

    # SQLite doesn't support dropping constraints, so we need to recreate the table
    # First, create a new table with the correct schema
    create table(:torrent_files_new) do
      add(:rd_id, :integer, null: false)
      add(:path, :text, null: false)
      add(:bytes, :integer, null: false)
      add(:selected, :integer, null: false)
      add(:link, :text)
      add(:torrent_hash, :string, null: false)
      add(:download_link, :text)
      add(:link_expires_at, :utc_datetime)
      add(:link_fetched_at, :utc_datetime)
      add(:hardlink_count, :integer, null: false, default: 1)
      add(:inode_id, references(:inodes, column: :inode_id, on_delete: :restrict))

      timestamps()
    end

    # Copy data from old table to new table, joining with torrents to get hash
    execute("""
    INSERT INTO torrent_files_new (
      id, rd_id, path, bytes, selected, link, torrent_hash,
      download_link, link_expires_at, link_fetched_at, hardlink_count,
      inode_id, inserted_at, updated_at
    )
    SELECT
      tf.id, tf.rd_id, tf.path, tf.bytes, tf.selected, tf.link,
      t.hash,
      tf.download_link, tf.link_expires_at, tf.link_fetched_at, tf.hardlink_count,
      tf.inode_id, tf.inserted_at, tf.updated_at
    FROM torrent_files tf
    JOIN torrents t ON t.id = tf.torrent_id
    """)

    # Drop old table
    drop(table(:torrent_files))

    # Rename new table to original name
    rename(table(:torrent_files_new), to: table(:torrent_files))

    # Create indexes
    create(unique_index(:torrent_files, [:torrent_hash, :rd_id]))
    create(index(:torrent_files, [:torrent_hash]))
    create(index(:torrent_files, [:inode_id]))
    create(index(:torrent_files, [:link_expires_at]))

    # ============================================================================
    # PART 2: Rename torrent directories from rd_id to hash
    # ============================================================================

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
    # ============================================================================
    # PART 1: Rename directories back from hash to rd_id
    # ============================================================================

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

    # ============================================================================
    # PART 2: Revert torrent_files table to use torrent_id
    # ============================================================================

    # Recreate with torrent_id
    create table(:torrent_files_new) do
      add(:rd_id, :integer, null: false)
      add(:path, :text, null: false)
      add(:bytes, :integer, null: false)
      add(:selected, :integer, null: false)
      add(:link, :text)
      add(:torrent_id, references(:torrents, on_delete: :delete_all), null: false)
      add(:download_link, :text)
      add(:link_expires_at, :utc_datetime)
      add(:link_fetched_at, :utc_datetime)
      add(:hardlink_count, :integer, null: false, default: 1)
      add(:inode_id, references(:inodes, column: :inode_id, on_delete: :restrict))

      timestamps()
    end

    # Copy data back, joining with torrents to get ID from hash
    execute("""
    INSERT INTO torrent_files_new (
      id, rd_id, path, bytes, selected, link, torrent_id,
      download_link, link_expires_at, link_fetched_at, hardlink_count,
      inode_id, inserted_at, updated_at
    )
    SELECT
      tf.id, tf.rd_id, tf.path, tf.bytes, tf.selected, tf.link,
      t.id,
      tf.download_link, tf.link_expires_at, tf.link_fetched_at, tf.hardlink_count,
      tf.inode_id, tf.inserted_at, tf.updated_at
    FROM torrent_files tf
    JOIN torrents t ON t.hash = tf.torrent_hash
    """)

    # Drop new table
    drop(table(:torrent_files))

    # Rename back
    rename(table(:torrent_files_new), to: table(:torrent_files))

    # Recreate indexes
    create(unique_index(:torrent_files, [:torrent_id, :rd_id]))
    create(index(:torrent_files, [:inode_id]))
    create(index(:torrent_files, [:link_expires_at]))
  end
end
