defmodule VFS.StreamabilityTest do
  use ExUnit.Case, async: false

  alias VFS
  alias VFS.Streamability
  alias SyncEngine.Torrents
  alias SyncEngine.Schemas.Torrent

  setup do
    # Explicitly get a connection checkout for the test
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(VFS.Repo)

    # Get or create root
    {:ok, root} = VFS.get_root()

    # Create a test torrent directory
    {:ok, torrent_dir} = VFS.create_directory(root.inode_id, "test_torrent_for_streaming")

    # Create a test torrent record
    {:ok, torrent} =
      Torrents.create_torrent(%{
        rd_id: "test_torrent_stream_123",
        filename: "Test Torrent For Streaming",
        hash: "testhash_stream_123",
        bytes: 1_000_000_000,
        host: "testhost.com",
        split: 0,
        progress: 100,
        status: "downloaded",
        added: "2024-01-01",
        ended: "2024-01-02",
        speed: 0,
        seeders: 0,
        inode_id: torrent_dir.inode_id
      })

    {:ok, root: root, torrent_dir: torrent_dir, torrent: torrent}
  end

  describe "streamable?/1 - Core Functionality" do
    test "returns false for regular files", %{root: root} do
      {:ok, file} = VFS.create_file(root.inode_id, "regular.txt", size: 100)
      refute Streamability.streamable?(file)
    end

    test "returns false for directories", %{root: root} do
      {:ok, dir} = VFS.create_directory(root.inode_id, "some_dir")
      refute Streamability.streamable?(dir)
    end

    test "returns false for POSIX hardlinks (not virtual inode)", %{root: root} do
      {:ok, target} = VFS.create_file(root.inode_id, "target.txt", size: 100)
      {:ok, hardlink} = VFS.create_hardlink(root.inode_id, "link.txt", target.inode_id)
      refute Streamability.streamable?(hardlink)
    end

    test "returns false for hardlink to virtual inode without link", %{
      torrent: torrent,
      torrent_dir: torrent_dir
    } do
      {:ok, virtual_inode} =
        Torrents.create_torrent_file(%{
          rd_id: 1,
          path: "/no_link_file.mkv",
          bytes: 1_000_000,
          selected: 1,
          link: nil,
          torrent_hash: torrent.hash,
          node_id: nil,
          hardlink_count: 1
        })

      {:ok, hardlink} =
        VFS.create_hardlink_to_virtual_inode(
          torrent_dir.inode_id,
          "no_link_file.mkv",
          virtual_inode.id
        )

      refute Streamability.streamable?(hardlink)
    end

    test "returns true for hardlink to virtual inode with link (queries database)", %{
      torrent: torrent,
      torrent_dir: torrent_dir
    } do
      {:ok, virtual_inode} =
        Torrents.create_torrent_file(%{
          rd_id: 1,
          path: "/streamable_file.mkv",
          bytes: 1_000_000,
          selected: 1,
          link: "https://example.com/download/streamable_file",
          torrent_hash: torrent.hash,
          node_id: nil,
          hardlink_count: 1
        })

      {:ok, hardlink} =
        VFS.create_hardlink_to_virtual_inode(
          torrent_dir.inode_id,
          "streamable_file.mkv",
          virtual_inode.id
        )

      # Will query the torrent_file internally
      assert Streamability.streamable?(hardlink)
    end

    test "returns true for hardlink with manually preloaded torrent_file", %{
      torrent: torrent,
      torrent_dir: torrent_dir
    } do
      {:ok, virtual_inode} =
        Torrents.create_torrent_file(%{
          rd_id: 1,
          path: "/preloaded_file.mkv",
          bytes: 1_000_000,
          selected: 1,
          link: "https://example.com/download/preloaded_file",
          torrent_hash: torrent.hash,
          node_id: nil,
          hardlink_count: 1
        })

      {:ok, hardlink} =
        VFS.create_hardlink_to_virtual_inode(
          torrent_dir.inode_id,
          "preloaded_file.mkv",
          virtual_inode.id
        )

      # Manually add the torrent_file to the node
      hardlink_with_tf = Map.put(hardlink, :torrent_file, %{link: virtual_inode.link})

      # Should be streamable using preloaded data
      assert Streamability.streamable?(hardlink_with_tf)
    end
  end

  describe "virtual_inode_streamable?/1" do
    test "returns true for torrent file with link", %{torrent: torrent} do
      {:ok, virtual_inode} =
        Torrents.create_torrent_file(%{
          rd_id: 1,
          path: "/test.mkv",
          bytes: 1_000_000,
          selected: 1,
          link: "https://example.com/download",
          torrent_hash: torrent.hash
        })

      assert Streamability.virtual_inode_streamable?(virtual_inode)
    end

    test "returns false for torrent file without link", %{torrent: torrent} do
      {:ok, virtual_inode} =
        Torrents.create_torrent_file(%{
          rd_id: 1,
          path: "/test.mkv",
          bytes: 1_000_000,
          selected: 1,
          link: nil,
          torrent_hash: torrent.hash
        })

      refute Streamability.virtual_inode_streamable?(virtual_inode)
    end

    test "returns false for non-map values" do
      refute Streamability.virtual_inode_streamable?(nil)
      refute Streamability.virtual_inode_streamable?("string")
      refute Streamability.virtual_inode_streamable?(123)
    end

    test "returns true for plain maps with link" do
      assert Streamability.virtual_inode_streamable?(%{link: "https://example.com"})
    end

    test "returns false for plain maps without link" do
      refute Streamability.virtual_inode_streamable?(%{id: 1})
      refute Streamability.virtual_inode_streamable?(%{link: nil})
    end
  end

  describe "preload_for_streamability/1" do
    test "returns empty list for empty input" do
      result = Streamability.preload_for_streamability([])
      assert result == []
    end

    test "returns non-list input unchanged" do
      node = %VFS.Node{id: 1, name: "test"}
      assert Streamability.preload_for_streamability(node) == node
    end

    test "preloads torrent files for hardlinks", %{
      torrent: torrent,
      torrent_dir: torrent_dir
    } do
      # Create virtual inode with link
      {:ok, vi} =
        Torrents.create_torrent_file(%{
          rd_id: 1,
          path: "/file1.mkv",
          bytes: 1_000_000,
          selected: 1,
          link: "https://example.com/file1",
          torrent_hash: torrent.hash,
          hardlink_count: 1
        })

      # Create hardlink
      {:ok, hl} =
        VFS.create_hardlink_to_virtual_inode(torrent_dir.inode_id, "file1.mkv", vi.id)

      # Create regular file
      {:ok, regular} = VFS.create_file(torrent_dir.inode_id, "regular.txt", size: 100)

      # Preload
      nodes = [hl, regular]
      preloaded = Streamability.preload_for_streamability(nodes)

      # Both should be streamable now (hardlink because it has preloaded data)
      assert Enum.at(preloaded, 0) |> Streamability.streamable?()
      refute Enum.at(preloaded, 1) |> Streamability.streamable?()

      # Hardlink should have torrent_file attached
      assert Map.has_key?(Enum.at(preloaded, 0), :torrent_file)
    end

    test "handles multiple hardlinks to same virtual inode", %{
      torrent: torrent,
      torrent_dir: torrent_dir
    } do
      # Create one virtual inode
      {:ok, vi} =
        Torrents.create_torrent_file(%{
          rd_id: 1,
          path: "/shared.mkv",
          bytes: 1_000_000,
          selected: 1,
          link: "https://example.com/shared",
          torrent_hash: torrent.hash,
          hardlink_count: 3
        })

      # Create three hardlinks to same virtual inode
      {:ok, hl1} =
        VFS.create_hardlink_to_virtual_inode(torrent_dir.inode_id, "link1.mkv", vi.id)

      {:ok, hl2} =
        VFS.create_hardlink_to_virtual_inode(torrent_dir.inode_id, "link2.mkv", vi.id)

      {:ok, hl3} =
        VFS.create_hardlink_to_virtual_inode(torrent_dir.inode_id, "link3.mkv", vi.id)

      # Preload (should query virtual inode only once)
      nodes = [hl1, hl2, hl3]
      preloaded = Streamability.preload_for_streamability(nodes)

      # All should be streamable
      assert Enum.all?(preloaded, &Streamability.streamable?/1)
    end
  end

  describe "Edge Cases and Error Handling" do
    test "handles invalid input types gracefully" do
      refute Streamability.streamable?(nil)
      refute Streamability.streamable?("not a node")
      refute Streamability.streamable?(123)
      refute Streamability.streamable?(%{})
    end

    test "preloading is idempotent", %{
      torrent: torrent,
      torrent_dir: torrent_dir
    } do
      {:ok, vi} =
        Torrents.create_torrent_file(%{
          rd_id: 1,
          path: "/idempotent.mkv",
          bytes: 1_000_000,
          selected: 1,
          link: "https://example.com/idempotent",
          torrent_hash: torrent.hash,
          hardlink_count: 1
        })

      {:ok, hardlink} =
        VFS.create_hardlink_to_virtual_inode(torrent_dir.inode_id, "idempotent.mkv", vi.id)

      # Preload once
      preloaded1 = Streamability.preload_for_streamability([hardlink])

      # Preload again
      preloaded2 = Streamability.preload_for_streamability(preloaded1)

      # Both should result in streamable hardlinks
      assert Enum.at(preloaded1, 0) |> Streamability.streamable?()
      assert Enum.at(preloaded2, 0) |> Streamability.streamable?()
    end
  end
end
