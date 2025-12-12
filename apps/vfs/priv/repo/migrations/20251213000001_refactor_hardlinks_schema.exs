defmodule VFS.Repo.Migrations.RefactorHardlinksSchema do
  use Ecto.Migration

  def change do
    alter table(:nodes) do
      # Add new explicit columns for different hardlink types
      add(:hardlink_target_node_id, :integer)
      add(:hardlink_target_torrent_file_id, :integer)
    end

    # Migrate existing hardlink data from single hardlink_target_id column
    # to the new explicit columns
    execute("""
    UPDATE nodes
    SET hardlink_target_node_id = hardlink_target_id
    WHERE is_hardlink = 1
      AND data IS NOT NULL
      AND data NOT LIKE 'vi:%'
    """)

    execute("""
    UPDATE nodes
    SET hardlink_target_torrent_file_id = hardlink_target_id
    WHERE is_hardlink = 1
      AND data IS NOT NULL
      AND data LIKE 'vi:%'
    """)

    # Add CHECK constraint to ensure exactly one target is set for hardlinks
    # For SQLite, we need to use a trigger instead since CHECK constraints can't reference other columns
    execute("""
    CREATE TRIGGER check_hardlink_target_insert
    BEFORE INSERT ON nodes
    FOR EACH ROW
    BEGIN
      SELECT CASE
        WHEN NEW.is_hardlink = 1 AND (
          (NEW.hardlink_target_node_id IS NULL AND NEW.hardlink_target_torrent_file_id IS NULL) OR
          (NEW.hardlink_target_node_id IS NOT NULL AND NEW.hardlink_target_torrent_file_id IS NOT NULL)
        ) THEN
          RAISE(ABORT, 'Hardlinks must have exactly one target')
      END;
    END;
    """)

    execute("""
    CREATE TRIGGER check_hardlink_target_update
    BEFORE UPDATE ON nodes
    FOR EACH ROW
    BEGIN
      SELECT CASE
        WHEN NEW.is_hardlink = 1 AND (
          (NEW.hardlink_target_node_id IS NULL AND NEW.hardlink_target_torrent_file_id IS NULL) OR
          (NEW.hardlink_target_node_id IS NOT NULL AND NEW.hardlink_target_torrent_file_id IS NOT NULL)
        ) THEN
          RAISE(ABORT, 'Hardlinks must have exactly one target')
      END;
    END;
    """)

    # Remove the old hardlink_target_id column
    alter table(:nodes) do
      remove(:hardlink_target_id)
    end
  end
end
