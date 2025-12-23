defmodule SyncEngine.TorrentsTest do
  use ExUnit.Case, async: false
  alias VFS.Repo
  alias SyncEngine.Torrents
  alias SyncEngine.Schemas.{Torrent, TorrentFile, RejectedTorrent}
  alias VFS

  setup do
    # Explicit checkout every test
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    # Setting the shared mode must be done only after checkout
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    # Create a root and test directory
    {:ok, root} = VFS.get_root()
    {:ok, test_dir} = VFS.create_directory(root.inode_id, "test_torrents")

    {:ok, test_dir: test_dir, root: root}
  end

  describe "torrents" do
    test "create_torrent/1 creates a torrent with valid attributes", %{test_dir: test_dir} do
      {:ok, node} = VFS.create_directory(test_dir.inode_id, "test_torrent")

      attrs = %{
        rd_id: "TEST123",
        filename: "Test Torrent",
        hash: "abc123def456",
        bytes: 1_000_000,
        status: "downloaded",
        inode_id: node.inode_id
      }

      assert {:ok, %Torrent{} = torrent} = Torrents.create_torrent(attrs)
      assert torrent.rd_id == "TEST123"
      assert torrent.filename == "Test Torrent"
      assert torrent.hash == "abc123def456"
      assert torrent.inode_id == node.inode_id
    end

    test "create_torrent/1 fails with duplicate rd_id", %{test_dir: test_dir} do
      {:ok, node1} = VFS.create_directory(test_dir.inode_id, "torrent1")
      {:ok, node2} = VFS.create_directory(test_dir.inode_id, "torrent2")

      attrs1 = %{
        rd_id: "DUPLICATE123",
        filename: "First",
        hash: "hash1",
        bytes: 100,
        inode_id: node1.inode_id
      }

      attrs2 = %{
        rd_id: "DUPLICATE123",
        filename: "Second",
        hash: "hash2",
        bytes: 200,
        inode_id: node2.inode_id
      }

      assert {:ok, _} = Torrents.create_torrent(attrs1)
      assert {:error, changeset} = Torrents.create_torrent(attrs2)
      assert "has already been taken" in errors_on(changeset).rd_id
    end

    test "get_torrent_by_rd_id/1 returns torrent", %{test_dir: test_dir} do
      {:ok, node} = VFS.create_directory(test_dir.inode_id, "test")

      attrs = %{
        rd_id: "FIND_ME",
        filename: "Find Me",
        hash: "hash",
        bytes: 100,
        inode_id: node.inode_id
      }

      {:ok, created} = Torrents.create_torrent(attrs)
      assert {:ok, found} = Torrents.get_torrent_by_rd_id("FIND_ME")
      assert found.id == created.id
    end

    test "delete_torrent/1 removes torrent", %{test_dir: test_dir} do
      {:ok, node} = VFS.create_directory(test_dir.inode_id, "delete_me")

      attrs = %{
        rd_id: "DELETE_ME",
        filename: "Delete Me",
        hash: "hash",
        bytes: 100,
        inode_id: node.inode_id
      }

      {:ok, torrent} = Torrents.create_torrent(attrs)
      assert {:ok, _} = Torrents.delete_torrent(torrent)
      assert {:error, :not_found} = Torrents.get_torrent_by_rd_id("DELETE_ME")
    end

    test "allows multiple torrents with same hash (different rd_ids)", %{test_dir: test_dir} do
      {:ok, node1} = VFS.create_directory(test_dir.inode_id, "torrent1")
      {:ok, node2} = VFS.create_directory(test_dir.inode_id, "torrent2")

      # Create first torrent with hash "same_hash_123"
      attrs1 = %{
        rd_id: "RD1",
        filename: "First Add",
        hash: "same_hash_123",
        bytes: 1_000_000,
        status: "downloaded",
        inode_id: node1.inode_id
      }

      {:ok, torrent1} = Torrents.create_torrent(attrs1)
      assert torrent1.rd_id == "RD1"
      assert torrent1.hash == "same_hash_123"

      # Create second torrent with same hash but different rd_id
      attrs2 = %{
        rd_id: "RD2",
        filename: "Re-added or Different RD",
        hash: "same_hash_123",
        bytes: 1_000_000,
        status: "magnet_conversion",
        inode_id: node2.inode_id
      }

      # This should succeed - multiple torrents can have same hash
      {:ok, torrent2} = Torrents.create_torrent(attrs2)
      assert torrent2.rd_id == "RD2"
      assert torrent2.hash == "same_hash_123"

      # Verify both torrents exist (different IDs)
      assert torrent1.id != torrent2.id

      # Verify both are in database
      assert {:ok, _} = Torrents.get_torrent_by_rd_id("RD1")
      assert {:ok, _} = Torrents.get_torrent_by_rd_id("RD2")
    end

    test "get_torrents_by_rd_id/0 returns map of torrents", %{test_dir: test_dir} do
      {:ok, node1} = VFS.create_directory(test_dir.inode_id, "t1")
      {:ok, node2} = VFS.create_directory(test_dir.inode_id, "t2")

      {:ok, _} =
        Torrents.create_torrent(%{
          rd_id: "T1",
          filename: "Torrent 1",
          hash: "h1",
          bytes: 100,
          inode_id: node1.inode_id
        })

      {:ok, _} =
        Torrents.create_torrent(%{
          rd_id: "T2",
          filename: "Torrent 2",
          hash: "h2",
          bytes: 200,
          inode_id: node2.inode_id
        })

      map = Torrents.get_torrents_by_rd_id()
      assert map_size(map) == 2
      assert Map.has_key?(map, "T1")
      assert Map.has_key?(map, "T2")
    end
  end

  describe "torrent_files" do
    setup %{test_dir: test_dir} do
      {:ok, torrent_node} = VFS.create_directory(test_dir.inode_id, "torrent")

      {:ok, torrent} =
        Torrents.create_torrent(%{
          rd_id: "TORRENT1",
          filename: "Test Torrent",
          hash: "hash",
          bytes: 1000,
          inode_id: torrent_node.inode_id
        })

      {:ok, file_node} = VFS.create_file(torrent_node.inode_id, "test_file.mp4", size: 500)

      {:ok, torrent: torrent, file_node: file_node}
    end

    test "create_torrent_file/1 creates file", %{torrent: torrent, file_node: file_node} do
      attrs = %{
        rd_id: 1,
        path: "/test_file.mp4",
        bytes: 500,
        selected: 1,
        torrent_hash: torrent.hash,
        torrent_rd_id: torrent.rd_id,
        inode_id: file_node.inode_id
      }

      assert {:ok, %TorrentFile{} = file} = Torrents.create_torrent_file(attrs)
      assert file.rd_id == 1
      assert file.path == "/test_file.mp4"
      assert file.torrent_hash == torrent.hash
    end

    test "list_torrent_files/1 returns files for torrent", %{
      torrent: torrent,
      file_node: file_node
    } do
      {:ok, _} =
        Torrents.create_torrent_file(%{
          rd_id: 1,
          path: "/file1.mp4",
          bytes: 500,
          selected: 1,
          torrent_hash: torrent.hash,
          torrent_rd_id: torrent.rd_id,
          inode_id: file_node.inode_id
        })

      files = Torrents.list_torrent_files(torrent.hash)
      assert length(files) == 1
    end

    test "delete_torrent cascades to files", %{torrent: torrent, file_node: file_node} do
      {:ok, _} =
        Torrents.create_torrent_file(%{
          rd_id: 1,
          path: "/file.mp4",
          bytes: 500,
          selected: 1,
          torrent_hash: torrent.hash,
          torrent_rd_id: torrent.rd_id,
          inode_id: file_node.inode_id
        })

      assert length(Torrents.list_torrent_files(torrent.hash)) == 1
      {:ok, _} = Torrents.delete_torrent(torrent)
      assert length(Torrents.list_torrent_files(torrent.hash)) == 0
    end

    test "create_torrent_file/1 creates virtual inode (inode_id: nil)", %{torrent: torrent} do
      # Virtual inodes don't have a VFS node yet - just the torrent_file record
      attrs = %{
        rd_id: 2,
        path: "/movie.mkv",
        bytes: 2_000_000,
        selected: 1,
        torrent_hash: torrent.hash,
        torrent_rd_id: torrent.rd_id,
        inode_id: nil,
        link: "https://real-debrid.com/unrestrict?link=abc123"
      }

      assert {:ok, %TorrentFile{} = file} = Torrents.create_torrent_file(attrs)
      assert file.rd_id == 2
      assert file.path == "/movie.mkv"
      assert file.torrent_hash == torrent.hash
      assert file.inode_id == nil
      assert file.hardlink_count == 1
      assert file.link == "https://real-debrid.com/unrestrict?link=abc123"
    end

    test "create_torrent_file/1 virtual inodes can have multiple hardlinks", %{torrent: torrent} do
      # Create virtual inode
      {:ok, virtual_inode} =
        Torrents.create_torrent_file(%{
          rd_id: 3,
          path: "/series.mkv",
          bytes: 3_000_000,
          selected: 1,
          torrent_hash: torrent.hash,
          torrent_rd_id: torrent.rd_id,
          inode_id: nil,
          link: "https://real-debrid.com/unrestrict?link=def456"
        })

      assert virtual_inode.hardlink_count == 1

      # Create multiple hardlinks to the same virtual inode
      {:ok, _hardlink1} =
        VFS.create_hardlink_to_virtual_inode(
          torrent.inode_id,
          "link1.mkv",
          virtual_inode.id,
          size: 3_000_000
        )

      {:ok, _hardlink2} =
        VFS.create_hardlink_to_virtual_inode(
          torrent.inode_id,
          "link2.mkv",
          virtual_inode.id,
          size: 3_000_000
        )

      # Verify virtual inode hardlink_count is incremented (was 1, now 3 after 2 more links)
      {:ok, reloaded} = Torrents.get_torrent_file_by_id(virtual_inode.id)
      assert reloaded.hardlink_count == 3

      # Decrement: after one decrement, count should be 2
      {:ok, {new_count, should_delete, _rd_id}} = Torrents.decrement_hardlink_count(reloaded)
      assert new_count == 2
      # FALSE because there are still 2 hardlinks remaining
      assert should_delete == false

      # For multi-file torrents, should_delete would be false unless all files have hardlink_count == 0
    end

    test "create_torrent_file/1 multi-file torrents require all files to reach 0", %{
      torrent: torrent
    } do
      # Create two virtual inodes in the same torrent
      {:ok, file1} =
        Torrents.create_torrent_file(%{
          rd_id: 4,
          path: "/movie.mkv",
          bytes: 5_000_000,
          selected: 1,
          torrent_hash: torrent.hash,
          torrent_rd_id: torrent.rd_id,
          inode_id: nil,
          link: "https://real-debrid.com/link1"
        })

      {:ok, file2} =
        Torrents.create_torrent_file(%{
          rd_id: 5,
          path: "/subtitle.srt",
          bytes: 100_000,
          selected: 1,
          torrent_hash: torrent.hash,
          torrent_rd_id: torrent.rd_id,
          inode_id: nil,
          link: "https://real-debrid.com/link2"
        })

      # Decrement file1: should_delete = false because file2 still has hardlink_count == 1
      {:ok, {count1, should_delete1, _rd_id}} = Torrents.decrement_hardlink_count(file1)
      assert count1 == 0
      # file2 still has hardlink_count == 1
      assert should_delete1 == false

      # Decrement file2: should_delete = true because now ALL files have hardlink_count == 0
      {:ok, {count2, should_delete2, _rd_id}} = Torrents.decrement_hardlink_count(file2)
      assert count2 == 0
      # NOW all files are at 0
      assert should_delete2 == true
    end

    test "create_torrent_file/1 merges on conflict with conditional upsert (torrent_hash + rd_id)", %{torrent: torrent} do
      # Create initial file
      attrs1 = %{
        rd_id: 10,
        path: "/original.mkv",
        bytes: 1_000_000,
        selected: 1,
        torrent_hash: torrent.hash,
        torrent_rd_id: torrent.rd_id,
        inode_id: nil,
        link: "https://real-debrid.com/link_old"
      }

      assert {:ok, file1} = Torrents.create_torrent_file(attrs1)
      assert file1.link == "https://real-debrid.com/link_old"
      assert file1.path == "/original.mkv"
      original_updated_at = file1.updated_at

      # Wait a moment to ensure different timestamp
      Process.sleep(10)

      # Insert same torrent_hash + rd_id with different data (merge with newer timestamp)
      attrs2 = %{
        rd_id: 10,
        path: "/updated.mkv",
        bytes: 2_000_000,
        selected: 1,
        torrent_hash: torrent.hash,
        torrent_rd_id: torrent.rd_id,
        inode_id: nil,
        link: "https://real-debrid.com/link_new"
      }

      # This should merge: keep existing record but update fields with newer timestamp
      assert {:ok, file2} = Torrents.create_torrent_file(attrs2)
      assert file2.link == "https://real-debrid.com/link_new"
      assert file2.path == "/updated.mkv"
      assert file2.bytes == 2_000_000
      # Verify the updated_at timestamp is newer or equal (merge updates timestamp)
      assert file2.updated_at >= original_updated_at

      # Verify only one record exists with this torrent_hash + rd_id combination
      files = Torrents.list_torrent_files(torrent.hash)
      matching_files = Enum.filter(files, fn f -> f.rd_id == 10 end)
      assert length(matching_files) == 1
      assert hd(matching_files).link == "https://real-debrid.com/link_new"
    end

    test "create_torrent_file/1 allows multiple different files under same hash", %{torrent: torrent} do
      # Scenario: Add same torrent hash, but select different files each time
      # First: add file1 (rd_id=100)
      attrs1 = %{
        rd_id: 100,
        path: "/file1.mkv",
        bytes: 1_000_000,
        selected: 1,
        torrent_hash: torrent.hash,
        torrent_rd_id: torrent.rd_id,
        link: "https://real-debrid.com/link1"
      }

      assert {:ok, file1} = Torrents.create_torrent_file(attrs1)
      assert file1.rd_id == 100
      assert file1.path == "/file1.mkv"

      # Second: add file2 (rd_id=200) - different file, same hash
      attrs2 = %{
        rd_id: 200,
        path: "/file2.mkv",
        bytes: 2_000_000,
        selected: 1,
        torrent_hash: torrent.hash,
        torrent_rd_id: torrent.rd_id,
        link: "https://real-debrid.com/link2"
      }

      assert {:ok, file2} = Torrents.create_torrent_file(attrs2)
      assert file2.rd_id == 200
      assert file2.path == "/file2.mkv"

      # Verify both files exist under the same hash
      files = Torrents.list_torrent_files(torrent.hash)
      assert length(files) == 2

      file1_from_db = Enum.find(files, fn f -> f.rd_id == 100 end)
      file2_from_db = Enum.find(files, fn f -> f.rd_id == 200 end)

      assert file1_from_db != nil
      assert file1_from_db.path == "/file1.mkv"
      assert file2_from_db != nil
      assert file2_from_db.path == "/file2.mkv"
    end
  end

  describe "rejected_torrents" do
    test "reject_torrent/1 creates rejected torrent" do
      attrs = %{
        rd_id: "REJECTED1",
        filename: "Bad Torrent",
        hash: "badhash",
        reason: "file_link_mismatch"
      }

      assert {:ok, %RejectedTorrent{} = rejected} = Torrents.reject_torrent(attrs)
      assert rejected.rd_id == "REJECTED1"
      assert rejected.reason == "file_link_mismatch"
      assert rejected.attempt_count == 1
      assert rejected.last_attempted_at != nil
    end

    test "torrent_rejected?/1 checks if torrent is rejected" do
      attrs = %{
        rd_id: "CHECK_REJECTED",
        filename: "Rejected",
        reason: "invalid_data"
      }

      assert Torrents.torrent_rejected?("CHECK_REJECTED") == false
      {:ok, _} = Torrents.reject_torrent(attrs)
      assert Torrents.torrent_rejected?("CHECK_REJECTED") == true
    end

    test "get_rejected_torrents_by_rd_id/0 returns map" do
      {:ok, _} =
        Torrents.reject_torrent(%{
          rd_id: "R1",
          filename: "Rejected 1",
          reason: "test"
        })

      {:ok, _} =
        Torrents.reject_torrent(%{
          rd_id: "R2",
          filename: "Rejected 2",
          reason: "test"
        })

      map = Torrents.get_rejected_torrents_by_rd_id()
      assert map_size(map) == 2
      assert Map.has_key?(map, "R1")
      assert Map.has_key?(map, "R2")
    end

    test "increment_rejection_attempts/1 increments counter" do
      {:ok, rejected} =
        Torrents.reject_torrent(%{
          rd_id: "INCREMENT_ME",
          filename: "Test",
          reason: "test"
        })

      assert rejected.attempt_count == 1

      {:ok, updated} = Torrents.increment_rejection_attempts(rejected)
      assert updated.attempt_count == 2
    end

    test "delete_rejected_torrent/1 removes rejected torrent" do
      {:ok, rejected} =
        Torrents.reject_torrent(%{
          rd_id: "DELETE_REJECTED",
          filename: "Test",
          reason: "test"
        })

      assert Torrents.torrent_rejected?("DELETE_REJECTED") == true
      {:ok, _} = Torrents.delete_rejected_torrent(rejected)
      assert Torrents.torrent_rejected?("DELETE_REJECTED") == false
    end
  end

  # Helper to extract errors from changeset
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
