defmodule VirtualInodeHardlinkTest do
  use ExUnit.Case

  alias VFS
  alias VFS.FileMode
  alias VFS.Repo
  alias SyncEngine.Torrents
  alias SyncEngine.Schemas.TorrentFile
  alias SyncEngine.Schemas.Torrent

  setup do
    # Explicitly get a connection checkout for the test
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)

    # Get or create root
    {:ok, root} = VFS.get_root()

    # Create a test torrent directory
    {:ok, torrent_dir} = VFS.create_directory(root.id, "test_torrent_123")

    # Create a test torrent record
    {:ok, torrent} =
      Torrents.create_torrent(%{
        rd_id: "test_torrent_123",
        filename: "Test Torrent",
        hash: "testhash123",
        bytes: 1_000_000_000,
        host: "testhost.com",
        split: 0,
        progress: 100,
        status: "downloaded",
        added: "2024-01-01",
        ended: "2024-01-02",
        speed: 0,
        seeders: 0,
        node_id: torrent_dir.id
      })

    {:ok, root: root, torrent_dir: torrent_dir, torrent: torrent}
  end

  describe "virtual inode hardlinks" do
    test "creates virtual inode without VFS file node", %{
      torrent: torrent,
      torrent_dir: torrent_dir
    } do
      # Create virtual inode (torrent file)
      {:ok, virtual_inode} =
        Torrents.create_torrent_file(%{
          rd_id: 1,
          path: "/testfile.mkv",
          bytes: 1_000_000,
          selected: 1,
          link: "https://example.com/link1",
          torrent_id: torrent.id,
          node_id: nil,
          hardlink_count: 1
        })

      assert virtual_inode.id
      assert virtual_inode.hardlink_count == 1
      assert is_nil(virtual_inode.node_id)
      assert virtual_inode.path == "/testfile.mkv"
    end

    test "creates hardlink to virtual inode", %{torrent: torrent, torrent_dir: torrent_dir} do
      # Create virtual inode
      {:ok, virtual_inode} =
        Torrents.create_torrent_file(%{
          rd_id: 1,
          path: "/testfile.mkv",
          bytes: 1_000_000,
          selected: 1,
          link: "https://example.com/link1",
          torrent_id: torrent.id,
          node_id: nil,
          hardlink_count: 1
        })

      # Create hardlink to virtual inode
      {:ok, hardlink} =
        VFS.create_hardlink_to_virtual_inode(
          torrent_dir.id,
          "testfile.mkv",
          virtual_inode.id,
          size: 1_000_000
        )

      assert hardlink.id
      assert hardlink.name == "testfile.mkv"
      assert hardlink.parent_id == torrent_dir.id
      assert hardlink.data == "vi:#{virtual_inode.id}"
      assert FileMode.regular?(hardlink.mode)
      assert hardlink.size == 1_000_000
      # content_type is no longer required - hardlinks are detected by mode + data
    end

    test "counts hardlinks to virtual inode", %{torrent: torrent, torrent_dir: torrent_dir} do
      # Create virtual inode
      {:ok, virtual_inode} =
        Torrents.create_torrent_file(%{
          rd_id: 1,
          path: "/testfile.mkv",
          bytes: 1_000_000,
          selected: 1,
          link: "https://example.com/link1",
          torrent_id: torrent.id,
          node_id: nil,
          hardlink_count: 1
        })

      # Initially no hardlinks
      assert VFS.count_hardlinks_to_virtual_inode(virtual_inode.id) == 0

      # Create first hardlink
      {:ok, _hardlink1} =
        VFS.create_hardlink_to_virtual_inode(
          torrent_dir.id,
          "file1.mkv",
          virtual_inode.id,
          size: 1_000_000
        )

      assert VFS.count_hardlinks_to_virtual_inode(virtual_inode.id) == 1

      # Create second hardlink
      {:ok, _hardlink2} =
        VFS.create_hardlink_to_virtual_inode(
          torrent_dir.id,
          "file2.mkv",
          virtual_inode.id,
          size: 1_000_000
        )

      assert VFS.count_hardlinks_to_virtual_inode(virtual_inode.id) == 2
    end

    test "finds all hardlinks to virtual inode", %{torrent: torrent, torrent_dir: torrent_dir} do
      # Create virtual inode
      {:ok, virtual_inode} =
        Torrents.create_torrent_file(%{
          rd_id: 1,
          path: "/testfile.mkv",
          bytes: 1_000_000,
          selected: 1,
          link: "https://example.com/link1",
          torrent_id: torrent.id,
          node_id: nil,
          hardlink_count: 1
        })

      # Create multiple hardlinks
      {:ok, hardlink1} =
        VFS.create_hardlink_to_virtual_inode(
          torrent_dir.id,
          "file1.mkv",
          virtual_inode.id,
          size: 1_000_000
        )

      {:ok, hardlink2} =
        VFS.create_hardlink_to_virtual_inode(
          torrent_dir.id,
          "file2.mkv",
          virtual_inode.id,
          size: 1_000_000
        )

      # Find all hardlinks
      hardlinks = VFS.find_all_hardlinks_to_virtual_inode(virtual_inode.id)

      assert length(hardlinks) == 2

      assert Enum.map(hardlinks, & &1.id) |> Enum.sort() ==
               Enum.map([hardlink1, hardlink2], & &1.id) |> Enum.sort()
    end

    test "extracts virtual inode ID from hardlink node", %{
      torrent: torrent,
      torrent_dir: torrent_dir
    } do
      # Create virtual inode
      {:ok, virtual_inode} =
        Torrents.create_torrent_file(%{
          rd_id: 1,
          path: "/testfile.mkv",
          bytes: 1_000_000,
          selected: 1,
          link: "http://example.com/link",
          torrent_id: torrent.id
        })

      # Create hardlink to virtual inode
      {:ok, hardlink} =
        VFS.create_hardlink_to_virtual_inode(torrent_dir.id, "hardlink.mkv", virtual_inode.id)

      # Extract should return the virtual inode ID
      {:ok, inode_id} = VFS.extract_virtual_inode_id(hardlink)
      assert inode_id == virtual_inode.id
    end

    test "extract fails for non-hardlinks", %{root: root} do
      # Create a regular file
      {:ok, file} = VFS.create_file(root.id, "regular.txt", size: 100)

      # Extract should fail
      assert VFS.extract_virtual_inode_id(file) == {:error, :not_a_hardlink}
    end

    test "extract fails for regular hardlinks", %{root: root} do
      # Create a regular file
      {:ok, target} = VFS.create_file(root.id, "target.txt", size: 100)

      # Create regular hardlink (POSIX hardlink, not virtual inode)
      {:ok, hardlink} = VFS.create_hardlink(root.id, "link.txt", target.id)

      # Extract should fail for regular hardlinks - they are not virtual inode hardlinks
      assert VFS.extract_virtual_inode_id(hardlink) == {:error, :not_virtual_inode}
    end
  end

  describe "hardlink reference counting" do
    test "increments hardlink count", %{torrent: torrent} do
      # Create virtual inode
      {:ok, virtual_inode} =
        Torrents.create_torrent_file(%{
          rd_id: 1,
          path: "/testfile.mkv",
          bytes: 1_000_000,
          selected: 1,
          link: "https://example.com/link1",
          torrent_id: torrent.id,
          node_id: nil,
          hardlink_count: 1
        })

      assert virtual_inode.hardlink_count == 1

      # Increment count
      {:ok, updated} = Torrents.increment_hardlink_count(virtual_inode)
      assert updated.hardlink_count == 2

      # Verify in database
      {:ok, fetched} = Torrents.get_torrent_file_by_id(virtual_inode.id)
      assert fetched.hardlink_count == 2
    end

    test "decrements hardlink count", %{torrent: torrent} do
      # Create virtual inode with count = 2
      {:ok, virtual_inode} =
        Torrents.create_torrent_file(%{
          rd_id: 1,
          path: "/testfile.mkv",
          bytes: 1_000_000,
          selected: 1,
          link: "https://example.com/link1",
          torrent_id: torrent.id,
          node_id: nil,
          hardlink_count: 2
        })

      # Decrement count
      {:ok, {new_count, should_delete}} = Torrents.decrement_hardlink_count(virtual_inode)
      assert new_count == 1
      assert should_delete == false

      # Decrement again to reach 0
      {:ok, virtual_inode} = Torrents.get_torrent_file_by_id(virtual_inode.id)
      {:ok, {new_count, should_delete}} = Torrents.decrement_hardlink_count(virtual_inode)
      assert new_count == 0
      assert should_delete == true
    end

    test "does not go below 0 when decrementing", %{torrent: torrent} do
      # Create virtual inode with count = 0
      {:ok, virtual_inode} =
        Torrents.create_torrent_file(%{
          rd_id: 1,
          path: "/testfile.mkv",
          bytes: 1_000_000,
          selected: 1,
          link: "https://example.com/link1",
          torrent_id: torrent.id,
          node_id: nil,
          hardlink_count: 0
        })

      # Try to decrement below 0
      {:ok, {new_count, _should_delete}} = Torrents.decrement_hardlink_count(virtual_inode)
      assert new_count == 0
    end

    test "verifies hardlink count consistency", %{torrent: torrent, torrent_dir: torrent_dir} do
      # Create virtual inode
      {:ok, virtual_inode} =
        Torrents.create_torrent_file(%{
          rd_id: 1,
          path: "/testfile.mkv",
          bytes: 1_000_000,
          selected: 1,
          link: "https://example.com/link1",
          torrent_id: torrent.id,
          node_id: nil,
          # Wrong count
          hardlink_count: 5
        })

      # Create actual hardlinks
      {:ok, _hardlink1} =
        VFS.create_hardlink_to_virtual_inode(
          torrent_dir.id,
          "file1.mkv",
          virtual_inode.id,
          size: 1_000_000
        )

      {:ok, _hardlink2} =
        VFS.create_hardlink_to_virtual_inode(
          torrent_dir.id,
          "file2.mkv",
          virtual_inode.id,
          size: 1_000_000
        )

      # Verify should auto-correct
      {:ok, verified} = Torrents.verify_hardlink_count(virtual_inode)
      assert verified.hardlink_count == 2
    end
  end

  describe "hardlink deletion" do
    test "removes hardlink node without affecting virtual inode", %{
      torrent: torrent,
      torrent_dir: torrent_dir
    } do
      # Create virtual inode
      {:ok, virtual_inode} =
        Torrents.create_torrent_file(%{
          rd_id: 1,
          path: "/testfile.mkv",
          bytes: 1_000_000,
          selected: 1,
          link: "https://example.com/link1",
          torrent_id: torrent.id,
          node_id: nil,
          hardlink_count: 1
        })

      # Create hardlink
      {:ok, hardlink} =
        VFS.create_hardlink_to_virtual_inode(
          torrent_dir.id,
          "testfile.mkv",
          virtual_inode.id,
          size: 1_000_000
        )

      # Remove hardlink
      :ok = VFS.remove_by_id(hardlink.id)

      # Verify hardlink is gone
      assert VFS.get_node(hardlink.id) == {:error, :not_found}

      # Verify virtual inode still exists
      {:ok, still_exists} = Torrents.get_torrent_file_by_id(virtual_inode.id)
      assert still_exists.id == virtual_inode.id
    end

    test "cascade deletes all hardlinks when removing torrent directory", %{
      torrent: torrent,
      torrent_dir: torrent_dir,
      root: root
    } do
      # Create virtual inode
      {:ok, virtual_inode} =
        Torrents.create_torrent_file(%{
          rd_id: 1,
          path: "/testfile.mkv",
          bytes: 1_000_000,
          selected: 1,
          link: "https://example.com/link1",
          torrent_id: torrent.id,
          node_id: nil,
          hardlink_count: 1
        })

      # Create hardlink
      {:ok, hardlink} =
        VFS.create_hardlink_to_virtual_inode(
          torrent_dir.id,
          "testfile.mkv",
          virtual_inode.id,
          size: 1_000_000
        )

      # Create a favorites directory with another hardlink
      {:ok, favorites} = VFS.create_directory(root.id, "favorites")

      {:ok, hardlink2} =
        VFS.create_hardlink_to_virtual_inode(
          favorites.id,
          "testfile.mkv",
          virtual_inode.id,
          size: 1_000_000
        )

      # Remove torrent directory with cascade
      :ok = VFS.remove_by_id(torrent_dir.id, cascade: true, cascade_hardlinks: true)

      # Verify hardlink in torrent_dir is gone
      assert VFS.get_node(hardlink.id) == {:error, :not_found}

      # Verify hardlink in favorites still exists (only torrent dir was deleted)
      {:ok, still_exists} = VFS.get_node(hardlink2.id)
      assert still_exists.id == hardlink2.id
    end
  end

  describe "backward compatibility - old hardlinks now have is_hardlink flag" do
    test "handles old-style hardlinks (non-virtual inode)", %{root: root} do
      # Create a regular file
      {:ok, file} =
        VFS.create_file(root.id, "original.txt",
          size: 100,
          content_type: "text/plain"
        )

      # Create old-style hardlink (stores target node ID in hardlink_target_id)
      {:ok, hardlink} = VFS.create_hardlink(root.id, "link.txt", file.id)

      # Hardlink should have is_hardlink set
      assert VFS.is_hardlink?(hardlink)
      assert hardlink.hardlink_target_id == file.id

      # Extract should return error since this is NOT a virtual inode hardlink
      assert VFS.extract_virtual_inode_id(hardlink) == {:error, :not_virtual_inode}
    end

    test "delete with cascade_hardlinks removes old-style hardlinks", %{root: root} do
      # Create a regular file
      {:ok, file} =
        VFS.create_file(root.id, "original.txt",
          size: 100,
          content_type: "text/plain"
        )

      # Create old-style hardlink
      {:ok, hardlink} = VFS.create_hardlink(root.id, "link.txt", file.id)

      # Remove file with cascade_hardlinks
      :ok = VFS.remove_by_id(file.id, cascade: true, cascade_hardlinks: true)

      # Both should be gone
      assert VFS.get_node(file.id) == {:error, :not_found}
      assert VFS.get_node(hardlink.id) == {:error, :not_found}
    end
  end
end
