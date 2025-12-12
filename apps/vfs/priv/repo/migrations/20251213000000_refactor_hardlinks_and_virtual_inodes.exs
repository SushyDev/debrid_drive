defmodule VFS.Repo.Migrations.RefactorHardlinksAndVirtualInodes do
  use Ecto.Migration

  def change do
    # Add columns (fresh database from prod doesn't have them)
    alter table(:nodes) do
      add(:is_hardlink, :integer, default: 0, null: false)
      add(:hardlink_target_id, :integer)
    end

    alter table(:torrent_files) do
      add(:hardlink_count, :integer, default: 1, null: false)
    end

    # Recreate tables without foreign keys temporarily to avoid constraint issues
    execute("""
    CREATE TABLE torrent_files_new (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      rd_id INTEGER NOT NULL,
      path TEXT NOT NULL,
      bytes INTEGER NOT NULL,
      selected INTEGER NOT NULL,
      link TEXT,
      torrent_id INTEGER NOT NULL,
      node_id INTEGER,
      download_link TEXT,
      link_expires_at DATETIME,
      link_fetched_at DATETIME,
      hardlink_count INTEGER NOT NULL DEFAULT 1,
      inserted_at DATETIME NOT NULL,
      updated_at DATETIME NOT NULL,
      UNIQUE(torrent_id, rd_id)
    );
    """)

    execute("""
    INSERT INTO torrent_files_new
    SELECT
      id,
      rd_id,
      path,
      bytes,
      selected,
      link,
      torrent_id,
      node_id,
      download_link,
      link_expires_at,
      link_fetched_at,
      hardlink_count,
      inserted_at,
      updated_at
    FROM torrent_files;
    """)

    execute("""
    CREATE TABLE torrents_new (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      rd_id TEXT NOT NULL UNIQUE,
      filename TEXT NOT NULL,
      hash TEXT NOT NULL UNIQUE,
      bytes INTEGER NOT NULL,
      host TEXT,
      split INTEGER,
      progress INTEGER,
      status TEXT,
      added TEXT,
      ended TEXT,
      speed INTEGER,
      seeders INTEGER,
      deletion_status TEXT,
      deletion_requested_at DATETIME,
      deletion_attempts INTEGER,
      deletion_last_attempted_at DATETIME,
      deletion_error TEXT,
      node_id INTEGER,
      inserted_at DATETIME NOT NULL,
      updated_at DATETIME NOT NULL
    );
    """)

    execute("""
    INSERT INTO torrents_new
    SELECT * FROM torrents;
    """)

    execute("DROP TABLE torrent_files;")
    execute("DROP TABLE torrents;")
    execute("ALTER TABLE torrent_files_new RENAME TO torrent_files;")
    execute("ALTER TABLE torrents_new RENAME TO torrents;")

    # Migrate existing hardlink data
    execute("""
    UPDATE nodes
    SET is_hardlink = 1,
        hardlink_target_id = CAST(SUBSTR(data, 4) AS INTEGER)
    WHERE data LIKE 'vi:%'
    """)

    execute("""
    UPDATE nodes
    SET is_hardlink = 1,
        hardlink_target_id = CAST(data AS INTEGER)
    WHERE data IS NOT NULL
      AND data != ''
      AND data NOT LIKE 'vi:%'
    """)

    # Convert existing torrent_files with node_id to virtual inodes
    execute("""
    UPDATE nodes
    SET is_hardlink = 1,
        hardlink_target_id = torrent_files.id,
        data = 'vi:' || torrent_files.id
    FROM torrent_files
    WHERE nodes.id = torrent_files.node_id
      AND torrent_files.node_id IS NOT NULL
    """)

    execute("""
    UPDATE torrent_files
    SET node_id = NULL
    WHERE node_id IS NOT NULL
    """)

    # Update regular hardlinks that point to nodes that are now virtual inode hardlinks
    # to point directly to the virtual inode
    execute("""
    UPDATE nodes
    SET hardlink_target_id = target_nodes.hardlink_target_id,
        data = 'vi:' || target_nodes.hardlink_target_id
    FROM nodes AS target_nodes
    WHERE nodes.is_hardlink = 1
      AND nodes.data NOT LIKE 'vi:%'
      AND target_nodes.id = nodes.hardlink_target_id
      AND target_nodes.is_hardlink = 1
      AND target_nodes.data LIKE 'vi:%'
    """)

    # Recreate indexes
    drop_if_exists(index(:torrent_files, [:link_expires_at]))
    create(index(:torrent_files, [:link_expires_at]))
  end
end
