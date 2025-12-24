defmodule SyncEngine.TorrentVerifierTest do
  use ExUnit.Case, async: false
  alias VFS.Repo
  alias SyncEngine.Torrents
  alias SyncEngine.Services.TorrentVerifier
  alias VFS

  setup do
    # Explicit checkout every test
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    # Setting the shared mode must be done only after checkout
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    # Create a root and test directory
    {:ok, root} = VFS.get_root()
    {:ok, test_dir} = VFS.create_directory(root.inode_id, "test_verifier")

    {:ok, test_dir: test_dir, root: root}
  end

  describe "verify_torrent/1" do
    test "keeps torrent when all files exist", %{test_dir: test_dir} do
      # Setup: Create torrent with valid files
      {:ok, torrent_node} = VFS.create_directory(test_dir.inode_id, "valid_torrent")
      {:ok, file_node} = VFS.create_file(torrent_node.inode_id, "video.mp4", size: 1000)

      {:ok, torrent} =
        Torrents.create_torrent(%{
          real_debrid_torrent_id: "VALID123",
          filename: "Valid Torrent",
          hash: "hash123",
          bytes: 1000,
          inode_id: torrent_node.inode_id
        })

      {:ok, _file} =
        Torrents.create_torrent_file(%{
          real_debrid_torrent_id: 1,
          path: "/video.mp4",
          bytes: 1000,
          selected: 1,
          real_debrid_real_debrid_torrent_hash: torrent.real_debrid_torrent_hash,
          torrent_real_debrid_torrent_id: torrent.real_debrid_torrent_id,
          inode_id: file_node.inode_id
        })

      # Execute
      result = TorrentVerifier.verify_torrent(torrent)

      # Assert: Nothing removed
      assert result.removed_files == 0
      assert result.removed_torrent == false
      assert result.errors == []

      # Torrent still exists
      assert {:ok, _} = Torrents.get_torrent_by_rd_id("VALID123")
      assert length(Torrents.list_torrent_files(torrent.real_debrid_torrent_hash)) == 1
    end

    test "handles torrent with no files", %{test_dir: test_dir} do
      # Setup: Create torrent without any files
      {:ok, torrent_node} = VFS.create_directory(test_dir.inode_id, "empty_torrent")

      {:ok, torrent} =
        Torrents.create_torrent(%{
          real_debrid_torrent_id: "EMPTY123",
          filename: "Empty Torrent",
          hash: "hash",
          bytes: 0,
          inode_id: torrent_node.inode_id
        })

      # Execute
      result = TorrentVerifier.verify_torrent(torrent)

      # Assert: Nothing removed (no files to check)
      assert result.removed_files == 0
      assert result.removed_torrent == false
      assert result.errors == []

      # Torrent still exists
      assert {:ok, _} = Torrents.get_torrent_by_rd_id("EMPTY123")
    end
  end

  describe "verify_all/0" do
    test "verifies all torrents and returns summary", %{test_dir: test_dir} do
      # Setup: Create multiple valid torrents
      {:ok, valid_node1} = VFS.create_directory(test_dir.inode_id, "valid1")
      {:ok, valid_file1} = VFS.create_file(valid_node1.inode_id, "file1.mp4", size: 100)

      {:ok, valid_torrent1} =
        Torrents.create_torrent(%{
          real_debrid_torrent_id: "VALID1",
          filename: "Valid 1",
          hash: "hash1",
          bytes: 100,
          inode_id: valid_node1.inode_id
        })

      {:ok, _} =
        Torrents.create_torrent_file(%{
          real_debrid_torrent_id: 1,
          path: "/file1.mp4",
          bytes: 100,
          selected: 1,
          real_debrid_real_debrid_torrent_hash: valid_torrent1.hash,
          torrent_real_debrid_torrent_id: valid_torrent1.rd_id,
          inode_id: valid_file1.inode_id
        })

      {:ok, valid_node2} = VFS.create_directory(test_dir.inode_id, "valid2")
      {:ok, valid_file2} = VFS.create_file(valid_node2.inode_id, "file2.mp4", size: 200)

      {:ok, valid_torrent2} =
        Torrents.create_torrent(%{
          real_debrid_torrent_id: "VALID2",
          filename: "Valid 2",
          hash: "hash2",
          bytes: 200,
          inode_id: valid_node2.inode_id
        })

      {:ok, _} =
        Torrents.create_torrent_file(%{
          real_debrid_torrent_id: 1,
          path: "/file2.mp4",
          bytes: 200,
          selected: 1,
          real_debrid_real_debrid_torrent_hash: valid_torrent2.hash,
          torrent_real_debrid_torrent_id: valid_torrent2.rd_id,
          inode_id: valid_file2.inode_id
        })

      # Execute
      {:ok, result} = TorrentVerifier.verify_all()

      # Assert: Summary is correct - all torrents valid
      assert result.verified == 2
      assert result.removed_files == 0
      assert result.removed_torrents == 0
      assert result.errors == []

      # Verify final state - all torrents still exist
      assert {:ok, _} = Torrents.get_torrent_by_rd_id("VALID1")
      assert {:ok, _} = Torrents.get_torrent_by_rd_id("VALID2")
    end

    test "handles empty torrent list" do
      # Execute with no torrents
      {:ok, result} = TorrentVerifier.verify_all()

      # Assert: All zeros
      assert result.verified == 0
      assert result.removed_files == 0
      assert result.removed_torrents == 0
      assert result.errors == []
    end
  end

  describe "verify_by_rd_id/1" do
    test "verifies torrent by RD ID", %{test_dir: test_dir} do
      # Setup
      {:ok, torrent_node} = VFS.create_directory(test_dir.inode_id, "by_rd_id")
      {:ok, file_node} = VFS.create_file(torrent_node.inode_id, "video.mp4", size: 1000)

      {:ok, torrent} =
        Torrents.create_torrent(%{
          real_debrid_torrent_id: "FIND_ME",
          filename: "Find Me",
          hash: "hash",
          bytes: 1000,
          inode_id: torrent_node.inode_id
        })

      {:ok, _} =
        Torrents.create_torrent_file(%{
          real_debrid_torrent_id: 1,
          path: "/video.mp4",
          bytes: 1000,
          selected: 1,
          real_debrid_real_debrid_torrent_hash: torrent.real_debrid_torrent_hash,
          torrent_real_debrid_torrent_id: torrent.real_debrid_torrent_id,
          inode_id: file_node.inode_id
        })

      # Execute
      {:ok, result} = TorrentVerifier.verify_by_rd_id("FIND_ME")

      # Assert
      assert result.removed_files == 0
      assert result.removed_torrent == false
    end

    test "returns error for non-existent RD ID" do
      # Execute
      result = TorrentVerifier.verify_by_rd_id("DOES_NOT_EXIST")

      # Assert
      assert result == {:error, :not_found}
    end
  end
end
