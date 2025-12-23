defmodule VFS.Repo.Migrations.AllowMultipleTorrentsPerHash do
  @moduledoc """
  Migration to allow multiple torrent records with the same hash but different rd_ids.

  This handles the real-world scenario where:
  - Same content (same hash) is added multiple times to Real-Debrid with different rd_ids
  - Different RD accounts add the same torrent
  - Torrents are deleted and re-added, getting new rd_ids

  Changes:
  1. Remove UNIQUE constraint on torrents.hash (keep rd_id as UNIQUE)
  2. Add torrent_rd_id field to torrent_files to track which torrent instance each file belongs to
  3. Update unique constraint on torrent_files to (torrent_hash, torrent_rd_id, rd_id)
  4. Backfill torrent_rd_id from existing data
  """
  use Ecto.Migration

  def up do
    # ============================================================================
    # PART 1: Remove unique constraint on torrents.hash
    # ============================================================================
    # SQLite doesn't support dropping constraints, so we recreate the table

    create table(:torrents_new, primary_key: false) do
      add(:id, :integer, primary_key: true)
      add(:rd_id, :string, null: false)
      add(:filename, :string, null: false)
      add(:hash, :string, null: false)
      add(:bytes, :bigint, null: false)
      add(:host, :string)
      add(:split, :integer)
      add(:progress, :integer)
      add(:status, :string)
      add(:added, :string)
      add(:ended, :string)
      add(:speed, :integer)
      add(:seeders, :integer)
      add(:inode_id, references(:inodes, column: :inode_id, on_delete: :restrict))

      # Deletion tracking fields
      add(:deletion_status, :string)
      add(:deletion_requested_at, :utc_datetime)
      add(:deletion_attempts, :integer, default: 0)
      add(:deletion_last_attempted_at, :utc_datetime)
      add(:deletion_error, :string)

      timestamps()
    end

    # Copy all data
    execute("""
    INSERT INTO torrents_new (
      id, rd_id, filename, hash, bytes, host, split, progress, status,
      added, ended, speed, seeders, inode_id,
      deletion_status, deletion_requested_at, deletion_attempts,
      deletion_last_attempted_at, deletion_error,
      inserted_at, updated_at
    )
    SELECT
      id, rd_id, filename, hash, bytes, host, split, progress, status,
      added, ended, speed, seeders, inode_id,
      deletion_status, deletion_requested_at, deletion_attempts,
      deletion_last_attempted_at, deletion_error,
      inserted_at, updated_at
    FROM torrents
    """)

    # Drop old table and rename
    drop(table(:torrents))
    rename(table(:torrents_new), to: table(:torrents))

    # Create indexes - rd_id is UNIQUE, hash is NOT unique (allows multiple torrents with same hash)
    create(unique_index(:torrents, [:rd_id]))
    create(index(:torrents, [:hash]))
    create(index(:torrents, [:inode_id]))
    create(index(:torrents, [:deletion_status]))

    # ============================================================================
    # PART 2: Add torrent_rd_id to torrent_files
    # ============================================================================

    # Create new torrent_files table with torrent_rd_id field
    create table(:torrent_files_new) do
      add(:rd_id, :integer, null: false)
      add(:path, :text, null: false)
      add(:bytes, :integer, null: false)
      add(:selected, :integer, null: false)
      add(:link, :text)
      add(:torrent_hash, :string, null: false)
      # NEW FIELD
      add(:torrent_rd_id, :string, null: false)
      add(:download_link, :text)
      add(:link_expires_at, :utc_datetime)
      add(:link_fetched_at, :utc_datetime)
      add(:hardlink_count, :integer, null: false, default: 1)
      add(:inode_id, references(:inodes, column: :inode_id, on_delete: :restrict))

      timestamps()
    end

    # Copy data and backfill torrent_rd_id from torrents table
    execute("""
    INSERT INTO torrent_files_new (
      id, rd_id, path, bytes, selected, link, torrent_hash, torrent_rd_id,
      download_link, link_expires_at, link_fetched_at, hardlink_count,
      inode_id, inserted_at, updated_at
    )
    SELECT
      tf.id, tf.rd_id, tf.path, tf.bytes, tf.selected, tf.link,
      tf.torrent_hash, t.rd_id as torrent_rd_id,
      tf.download_link, tf.link_expires_at, tf.link_fetched_at, tf.hardlink_count,
      tf.inode_id, tf.inserted_at, tf.updated_at
    FROM torrent_files tf
    JOIN torrents t ON t.hash = tf.torrent_hash
    """)

    # Drop old table and rename
    drop(table(:torrent_files))
    rename(table(:torrent_files_new), to: table(:torrent_files))

    # Create new indexes - unique constraint is now (torrent_hash, torrent_rd_id, rd_id)
    # This means: same file (rd_id) can exist under same hash, but only once per torrent instance
    create(unique_index(:torrent_files, [:torrent_hash, :torrent_rd_id, :rd_id]))
    create(index(:torrent_files, [:torrent_hash]))
    create(index(:torrent_files, [:torrent_rd_id]))
    create(index(:torrent_files, [:inode_id]))
    create(index(:torrent_files, [:link_expires_at]))

    # ============================================================================
    # PART 3: Update cascade delete trigger for new schema
    # ============================================================================
    # Drop old trigger (from previous migration)
    execute("DROP TRIGGER IF EXISTS delete_torrent_files_on_torrent_delete")

    # Create new trigger that filters by both hash AND rd_id
    execute("""
    CREATE TRIGGER cascade_delete_torrent_files
    AFTER DELETE ON torrents
    FOR EACH ROW
    BEGIN
      DELETE FROM torrent_files WHERE torrent_hash = OLD.hash AND torrent_rd_id = OLD.rd_id;
    END;
    """)
  end

  def down do
    # Drop the new trigger
    execute("DROP TRIGGER IF EXISTS cascade_delete_torrent_files")

    # Recreate old trigger (with old name)
    execute("""
    CREATE TRIGGER delete_torrent_files_on_torrent_delete
    BEFORE DELETE ON torrents
    FOR EACH ROW
    BEGIN
      DELETE FROM torrent_files WHERE torrent_hash = OLD.hash;
    END;
    """)

    # Revert torrent_files schema (remove torrent_rd_id)
    create table(:torrent_files_old) do
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

    execute("""
    INSERT INTO torrent_files_old (
      id, rd_id, path, bytes, selected, link, torrent_hash,
      download_link, link_expires_at, link_fetched_at, hardlink_count,
      inode_id, inserted_at, updated_at
    )
    SELECT
      id, rd_id, path, bytes, selected, link, torrent_hash,
      download_link, link_expires_at, link_fetched_at, hardlink_count,
      inode_id, inserted_at, updated_at
    FROM torrent_files
    """)

    drop(table(:torrent_files))
    rename(table(:torrent_files_old), to: table(:torrent_files))

    create(unique_index(:torrent_files, [:torrent_hash, :rd_id]))
    create(index(:torrent_files, [:torrent_hash]))
    create(index(:torrent_files, [:inode_id]))
    create(index(:torrent_files, [:link_expires_at]))

    # Revert torrents schema (add back unique constraint on hash)
    create table(:torrents_old, primary_key: false) do
      add(:id, :integer, primary_key: true)
      add(:rd_id, :string, null: false)
      add(:filename, :string, null: false)
      add(:hash, :string, null: false)
      add(:bytes, :bigint, null: false)
      add(:host, :string)
      add(:split, :integer)
      add(:progress, :integer)
      add(:status, :string)
      add(:added, :string)
      add(:ended, :string)
      add(:speed, :integer)
      add(:seeders, :integer)
      add(:inode_id, references(:inodes, column: :inode_id, on_delete: :restrict))

      add(:deletion_status, :string)
      add(:deletion_requested_at, :utc_datetime)
      add(:deletion_attempts, :integer, default: 0)
      add(:deletion_last_attempted_at, :utc_datetime)
      add(:deletion_error, :string)

      timestamps()
    end

    execute("""
    INSERT INTO torrents_old (
      id, rd_id, filename, hash, bytes, host, split, progress, status,
      added, ended, speed, seeders, inode_id,
      deletion_status, deletion_requested_at, deletion_attempts,
      deletion_last_attempted_at, deletion_error,
      inserted_at, updated_at
    )
    SELECT
      id, rd_id, filename, hash, bytes, host, split, progress, status,
      added, ended, speed, seeders, inode_id,
      deletion_status, deletion_requested_at, deletion_attempts,
      deletion_last_attempted_at, deletion_error,
      inserted_at, updated_at
    FROM torrents
    """)

    drop(table(:torrents))
    rename(table(:torrents_old), to: table(:torrents))

    create(unique_index(:torrents, [:rd_id]))
    create(unique_index(:torrents, [:hash]))
    create(index(:torrents, [:inode_id]))
    create(index(:torrents, [:deletion_status]))
  end
end
