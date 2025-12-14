defmodule VFS.Repo.Migrations.UseTorrentHashInsteadOfId do
  @moduledoc """
  Migration to use torrent hash instead of torrent ID for binding torrent files.

  This makes the system more resilient to torrent ID changes when torrents are
  removed and re-added to Real-Debrid, since the hash remains constant.

  Changes:
  1. Recreate torrent_files table with torrent_hash instead of torrent_id
  2. Preserve all existing data during the migration
  """
  use Ecto.Migration

  def up do
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
  end

  def down do
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
