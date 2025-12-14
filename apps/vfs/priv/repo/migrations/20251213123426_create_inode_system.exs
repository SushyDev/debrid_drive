defmodule VFS.Repo.Migrations.CreateInodeSystem do
  use Ecto.Migration

  def up do
    # ============================================================================
    # PHASE 1: Create New Tables
    # ============================================================================

    # Create inodes table - stores file metadata (the "inode" in POSIX terms)
    create table(:inodes, primary_key: false) do
      add(:inode_id, :integer, primary_key: true, null: false)

      # File metadata
      add(:mode, :integer, null: false)
      add(:size, :integer, default: 0, null: false)
      add(:data, :binary)
      add(:content_type, :string)

      # Hardlink tracking (POSIX st_nlink)
      add(:nlink, :integer, default: 1, null: false)

      # Virtual inode support (for RealDebrid streamable files)
      # e.g. "torrent_file"
      add(:virtual_inode_type, :string)
      # e.g. torrent_file.id
      add(:virtual_inode_id, :integer)

      timestamps()
    end

    # Indexes for inodes
    create(index(:inodes, [:virtual_inode_type, :virtual_inode_id]))

    create(
      unique_index(:inodes, [:virtual_inode_type, :virtual_inode_id],
        where: "virtual_inode_type IS NOT NULL",
        name: :inodes_virtual_inode_unique_index
      )
    )

    # Create directory_entries table - maps names to inodes (like directory entries)
    create table(:directory_entries) do
      add(:parent_inode_id, references(:inodes, column: :inode_id, on_delete: :delete_all), null: false)

      add(:name, :string, null: false)
      add(:inode_id, references(:inodes, column: :inode_id, on_delete: :restrict), null: false)

      timestamps()
    end

    # Indexes for directory_entries
    create(index(:directory_entries, [:parent_inode_id]))
    create(index(:directory_entries, [:inode_id]))
    create(unique_index(:directory_entries, [:parent_inode_id, :name]))

    # ============================================================================
    # PHASE 2: Migrate Data from nodes → inodes + directory_entries
    # ============================================================================

    execute(&migrate_data_up/0)

    # ============================================================================
    # PHASE 3: Update Foreign Keys
    # ============================================================================

    # Update torrents table to reference inodes instead of nodes
    alter table(:torrents) do
      add(:inode_id, references(:inodes, column: :inode_id, on_delete: :restrict))
    end

    # Migrate torrent.node_id → torrent.inode_id
    execute("""
    UPDATE torrents
    SET inode_id = (
      SELECT new_inode_id 
      FROM node_to_inode_map 
      WHERE old_node_id = torrents.node_id
    )
    WHERE node_id IS NOT NULL
    """)

    # Update torrent_files table
    alter table(:torrent_files) do
      add(:inode_id, references(:inodes, column: :inode_id, on_delete: :restrict))
    end

    # Migrate torrent_files.node_id → torrent_files.inode_id using virtual inode mapping
    execute("""
    UPDATE torrent_files
    SET inode_id = (
      SELECT inode_id 
      FROM inodes 
      WHERE inodes.virtual_inode_type = 'torrent_file' 
        AND inodes.virtual_inode_id = torrent_files.id
    )
    WHERE node_id IS NOT NULL
    """)

    # Clean up temporary tables now that foreign keys are migrated
    execute(&cleanup_migration_data/0)

    # Drop old node_id columns after migration
    alter table(:torrents) do
      remove(:node_id)
    end

    alter table(:torrent_files) do
      remove(:node_id)
    end

    # Create indexes on new inode_id columns
    create(index(:torrents, [:inode_id]))
    create(index(:torrent_files, [:inode_id]))

    # ============================================================================
    # PHASE 4: Drop old nodes table (SAFETY: Keep commented out initially)
    # ============================================================================

    # SAFETY CHECKLIST - Only uncomment the drop statement below after ALL of:
    #   1. Migration has run successfully in production for at least 30 days
    #   2. All application code verified to no longer reference :nodes table
    #   3. Verified backups of :nodes table data exist and are restorable
    #   4. Database query logs confirm no queries against :nodes table
    #   5. Team has reviewed and approved the permanent removal
    #   6. Rollback plan documented in case of issues
    #
    # When ready to drop:
    # drop table(:nodes)
  end

  def down do
    # WARNING: This rollback will lose data!
    # Only use if migration just ran and you have a backup

    # Restore nodes table structure (will be empty)
    create table(:nodes) do
      add(:parent_id, references(:nodes, on_delete: :delete_all), null: true)
      add(:name, :string, null: false)
      add(:mode, :integer, null: false)
      add(:content_type, :string)
      add(:size, :integer, default: 0)
      add(:data, :binary)
      add(:is_hardlink, :boolean, default: false)
      add(:hardlink_target_node_id, references(:nodes, on_delete: :nilify_all))
      add(:hardlink_target_torrent_file_id, :integer)

      timestamps()
    end

    create(index(:nodes, [:parent_id]))
    create(unique_index(:nodes, [:parent_id, :name]))

    # Restore foreign keys in torrents and torrent_files
    alter table(:torrents) do
      add(:node_id, references(:nodes, on_delete: :restrict))
      remove(:inode_id)
    end

    alter table(:torrent_files) do
      add(:node_id, references(:nodes, on_delete: :restrict))
      remove(:inode_id)
    end

    # Drop new tables
    drop(table(:directory_entries))
    drop(table(:inodes))

    # Note: Data is lost! Restore from backup if needed
  end

  # ============================================================================
  # Data Migration Logic
  # ============================================================================

  defp migrate_data_up do
    VFS.Repo.transact(
      fn ->
        # Create temporary mapping tables
        VFS.Repo.query!("""
        CREATE TEMP TABLE node_to_inode_map (
          old_node_id INTEGER PRIMARY KEY,
          new_inode_id INTEGER NOT NULL
        )
        """)

        VFS.Repo.query!("""
        CREATE TEMP TABLE virtual_inode_map (
          torrent_file_id INTEGER PRIMARY KEY,
          inode_id INTEGER NOT NULL
        )
        """)

        VFS.Repo.query!("""
        CREATE TEMP TABLE broken_posix_hardlinks (
          node_id INTEGER PRIMARY KEY,
          parent_id INTEGER,
          name TEXT,
          target_node_id INTEGER,
          reason TEXT
        )
        """)

        # ========================================================================
        # STEP 1: Create Root Inode (inode_id = 1)
        # ========================================================================

        VFS.Repo.query!("""
        INSERT INTO inodes (inode_id, mode, size, nlink, inserted_at, updated_at)
        SELECT 
          1,
          mode,
          0,
          1,
          inserted_at,
          updated_at
        FROM nodes
        WHERE parent_id IS NULL AND name = '/'
        """)

        VFS.Repo.query!("""
        INSERT INTO node_to_inode_map (old_node_id, new_inode_id)
        SELECT id, 1
        FROM nodes
        WHERE parent_id IS NULL AND name = '/'
        """)

        # ========================================================================
        # STEP 2: Create Inodes for Regular Files/Directories
        # ========================================================================

        # Insert regular inodes (non-hardlink nodes)
        VFS.Repo.query!("""
        INSERT INTO inodes (mode, size, data, content_type, nlink, inserted_at, updated_at)
        SELECT 
          mode,
          COALESCE(size, 0),
          data,
          content_type,
          1,
          inserted_at,
          updated_at
        FROM nodes
        WHERE (is_hardlink = 0 OR is_hardlink IS NULL)
          AND parent_id IS NOT NULL
        ORDER BY id
        """)

        # Build mapping using row number correlation
        VFS.Repo.query!("""
        INSERT INTO node_to_inode_map (old_node_id, new_inode_id)
        SELECT 
          n.id,
          i.inode_id
        FROM (
          SELECT 
            id,
            mode,
            COALESCE(size, 0) as size,
            inserted_at,
            ROW_NUMBER() OVER (ORDER BY id) as row_num
          FROM nodes
          WHERE (is_hardlink = 0 OR is_hardlink IS NULL)
            AND parent_id IS NOT NULL
        ) n
        JOIN (
          SELECT 
            inode_id,
            mode,
            size,
            inserted_at,
            ROW_NUMBER() OVER (ORDER BY inode_id) as row_num
          FROM inodes
          WHERE inode_id != 1
            AND virtual_inode_type IS NULL
        ) i ON n.row_num = i.row_num 
          AND n.mode = i.mode 
          AND n.size = i.size
          AND n.inserted_at = i.inserted_at
        """)

        # ========================================================================
        # STEP 3: Create Directory Entries for Regular Files/Directories
        # ========================================================================

        VFS.Repo.query!("""
        INSERT INTO directory_entries (parent_inode_id, name, inode_id, inserted_at, updated_at)
        SELECT 
          parent_map.new_inode_id,
          n.name,
          child_map.new_inode_id,
          n.inserted_at,
          n.updated_at
        FROM nodes n
        JOIN node_to_inode_map child_map ON n.id = child_map.old_node_id
        JOIN node_to_inode_map parent_map ON n.parent_id = parent_map.old_node_id
        WHERE (n.is_hardlink = 0 OR n.is_hardlink IS NULL)
          AND n.parent_id IS NOT NULL
        """)

        # ========================================================================
        # STEP 4: Create Virtual Inodes (Streamable Files)
        # ========================================================================

        # Create one inode per unique torrent_file_id
        VFS.Repo.query!("""
        INSERT INTO inodes (
          mode,
          size,
          nlink,
          virtual_inode_type,
          virtual_inode_id,
          inserted_at,
          updated_at
        )
        SELECT 
          MIN(mode) as mode,
          MIN(size) as size,
          COUNT(*) as nlink,
          'torrent_file',
          hardlink_target_torrent_file_id,
          MIN(inserted_at),
          MAX(updated_at)
        FROM nodes
        WHERE is_hardlink = 1 
          AND hardlink_target_torrent_file_id IS NOT NULL
        GROUP BY hardlink_target_torrent_file_id
        """)

        # Build virtual inode mapping
        VFS.Repo.query!("""
        INSERT INTO virtual_inode_map (torrent_file_id, inode_id)
        SELECT virtual_inode_id, inode_id
        FROM inodes
        WHERE virtual_inode_type = 'torrent_file'
        """)

        # ========================================================================
        # STEP 5: Create Directory Entries for Virtual Inode Hardlinks
        # ========================================================================

        VFS.Repo.query!("""
        INSERT INTO directory_entries (parent_inode_id, name, inode_id, inserted_at, updated_at)
        SELECT 
          parent_map.new_inode_id,
          n.name,
          vi_map.inode_id,
          n.inserted_at,
          n.updated_at
        FROM nodes n
        JOIN node_to_inode_map parent_map ON n.parent_id = parent_map.old_node_id
        JOIN virtual_inode_map vi_map ON n.hardlink_target_torrent_file_id = vi_map.torrent_file_id
        WHERE n.is_hardlink = 1 
          AND n.hardlink_target_torrent_file_id IS NOT NULL
        """)

        # ========================================================================
        # STEP 6: Handle POSIX Hardlinks
        # ========================================================================

        # Identify broken hardlinks
        VFS.Repo.query!("""
        INSERT INTO broken_posix_hardlinks (node_id, parent_id, name, target_node_id, reason)
        SELECT 
          id,
          parent_id,
          name,
          hardlink_target_node_id,
          CASE 
            WHEN hardlink_target_node_id = 0 THEN 'Target ID is 0'
            WHEN hardlink_target_node_id NOT IN (SELECT id FROM nodes) THEN 'Target does not exist'
            ELSE 'Unknown'
          END as reason
        FROM nodes
        WHERE is_hardlink = 1
          AND hardlink_target_node_id IS NOT NULL
          AND (
            hardlink_target_node_id = 0 OR
            hardlink_target_node_id NOT IN (SELECT id FROM nodes)
          )
        """)

        # Create directory entries for valid POSIX hardlinks
        VFS.Repo.query!("""
        INSERT INTO directory_entries (parent_inode_id, name, inode_id, inserted_at, updated_at)
        SELECT 
          parent_map.new_inode_id,
          n.name,
          target_map.new_inode_id,
          n.inserted_at,
          n.updated_at
        FROM nodes n
        JOIN node_to_inode_map parent_map ON n.parent_id = parent_map.old_node_id
        JOIN node_to_inode_map target_map ON n.hardlink_target_node_id = target_map.old_node_id
        WHERE n.is_hardlink = 1
          AND n.hardlink_target_node_id IS NOT NULL
          AND n.hardlink_target_node_id != 0
          AND n.hardlink_target_node_id IN (SELECT old_node_id FROM node_to_inode_map)
        """)

        # Increment nlink for each POSIX hardlink
        VFS.Repo.query!("""
        UPDATE inodes
        SET nlink = nlink + (
          SELECT COUNT(*)
          FROM nodes n
          JOIN node_to_inode_map target_map ON n.hardlink_target_node_id = target_map.old_node_id
          WHERE target_map.new_inode_id = inodes.inode_id
            AND n.is_hardlink = 1
            AND n.hardlink_target_node_id IS NOT NULL
            AND n.hardlink_target_node_id != 0
        )
        WHERE EXISTS (
          SELECT 1
          FROM nodes n
          JOIN node_to_inode_map target_map ON n.hardlink_target_node_id = target_map.old_node_id
          WHERE target_map.new_inode_id = inodes.inode_id
            AND n.is_hardlink = 1
            AND n.hardlink_target_node_id IS NOT NULL
        )
        """)

        # ========================================================================
        # VERIFICATION
        # ========================================================================

        # Log broken hardlinks if any
        broken_count = VFS.Repo.query!("SELECT COUNT(*) FROM broken_posix_hardlinks", [])
        broken_count_value = broken_count.rows |> List.first() |> List.first()

        if broken_count_value > 0 do
          broken = VFS.Repo.query!("SELECT * FROM broken_posix_hardlinks", [])

          IO.puts("WARNING: #{broken_count_value} broken POSIX hardlinks skipped:")

          Enum.each(broken.rows, fn row ->
            IO.puts("  Node #{Enum.at(row, 0)}: #{Enum.at(row, 2)} -> target #{Enum.at(row, 3)} (#{Enum.at(row, 4)})")
          end)
        end

        # Verify counts
        inode_count = VFS.Repo.query!("SELECT COUNT(*) FROM inodes", [])
        entry_count = VFS.Repo.query!("SELECT COUNT(*) FROM directory_entries", [])

        IO.puts("Migration complete:")
        IO.puts("  - Inodes created: #{inode_count.rows |> List.first() |> List.first()}")

        IO.puts("  - Directory entries created: #{entry_count.rows |> List.first() |> List.first()}")

        # Verify nlink integrity
        nlink_check =
          VFS.Repo.query!(
            """
            SELECT COUNT(*)
            FROM inodes i
            LEFT JOIN directory_entries de ON de.inode_id = i.inode_id
            WHERE i.inode_id != 1
            GROUP BY i.inode_id, i.nlink
            HAVING i.nlink != COUNT(de.id)
            """,
            []
          )

        if nlink_check.rows != [] do
          IO.puts("WARNING: nlink mismatches found! Run verification queries.")
        else
          IO.puts("  - nlink counts verified: OK")
        end

        # NOTE: We do NOT drop the temp tables here because they're needed for
        # the foreign key migration that happens after columns are added in up/0.
        # Temp tables will be dropped explicitly in cleanup_migration_data/0.
      end,
      timeout: :infinity
    )
  end

  defp cleanup_migration_data do
    # Drop temporary tables used during migration
    VFS.Repo.query!("DROP TABLE IF EXISTS node_to_inode_map", [])
    VFS.Repo.query!("DROP TABLE IF EXISTS virtual_inode_map", [])
    VFS.Repo.query!("DROP TABLE IF EXISTS broken_posix_hardlinks", [])
  end
end
