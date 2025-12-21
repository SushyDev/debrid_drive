defmodule GrpcServer.E2E.CopyStreamableHardlinkTest do
  @moduledoc """
  End-to-end tests for copying streamable hardlinks.

  When a user copies a streamable hardlink (e.g., via file manager), the operation
  should create another hardlink to the same virtual inode, NOT copy the actual
  stream data (which could be gigabytes from RealDebrid).

  This test validates that:
  1. Copying via Link RPC creates a new hardlink correctly
  2. Multiple hardlinks point to the same virtual inode
  3. Both copies are streamable
  4. The hardlink count is properly tracked
  5. Deleting one copy doesn't affect the other
  """
  use ExUnit.Case, async: false

  import GrpcServer.Test.GrpcClientHelper

  alias VFS
  alias VFS.FileMode
  alias SyncEngine.Schemas.{Torrent, TorrentFile}

  setup do
    :ok = GrpcTestHelper.cleanup_database()

    :ok = GrpcTestHelper.wait_for_db_ready()

    channel = connect()

    on_exit(fn ->
      disconnect(channel)
    end)

    {:ok, channel: channel}
  end

  # Helper to create a streamable virtual inode with a hardlink
  defp create_streamable_file(root_id, filename, size \\ 5_000_000_000) do
    # Create a torrent
    {:ok, torrent} =
      VFS.Repo.insert(%Torrent{
        rd_id: "test-#{System.unique_integer()}",
        filename: filename,
        hash: "testhash#{System.unique_integer()}",
        bytes: size,
        host: "rd.example.com",
        split: 0,
        progress: 100,
        status: "downloaded",
        added: "2025-01-01T00:00:00Z",
        ended: "2025-01-01T00:00:00Z",
        speed: 0,
        seeders: 10
      })

    # Create a torrent_file (virtual inode) with a link (streamable)
    {:ok, torrent_file} =
      VFS.Repo.insert(%TorrentFile{
        torrent_hash: torrent.hash,
        rd_id: 1,
        path: "/#{filename}",
        bytes: size,
        selected: 1,
        # With a link, it's streamable
        link: "https://real-debrid.com/d/EXAMPLE#{System.unique_integer()}",
        hardlink_count: 0
      })

    # Create the first hardlink to the virtual inode
    # Note: create_hardlink_to_virtual_inode automatically increments the hardlink count
    {:ok, hardlink} =
      VFS.create_hardlink_to_virtual_inode(root_id, filename, torrent_file.id, size: size)

    # Reload the torrent_file to get the updated hardlink_count
    {:ok, updated_torrent_file} = SyncEngine.Torrents.get_torrent_file_by_id(torrent_file.id)

    {hardlink, updated_torrent_file}
  end

  describe "Copy streamable hardlink via Link RPC" do
    test "creates a new hardlink to the same virtual inode", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create a streamable file (5GB video)
      {original_hardlink, virtual_inode} =
        create_streamable_file(root_id, "big_movie.mkv", 5_000_000_000)

      # Verify the original is streamable
      {:ok, lookup_resp} = lookup(channel, root_id, "big_movie.mkv")
      assert lookup_resp.node.streamable == true
      assert lookup_resp.node.size == 5_000_000_000
      assert lookup_resp.node.id == original_hardlink.inode_id

      # "Copy" the file using Link RPC (what should happen in file managers)
      {:ok, copy_resp} =
        create_link(channel, original_hardlink.inode_id, root_id, "big_movie_copy.mkv")

      # Verify the copy exists and is streamable
      {:ok, copy_lookup_resp} = lookup(channel, root_id, "big_movie_copy.mkv")
      assert copy_lookup_resp.node.streamable == true
      assert copy_lookup_resp.node.size == 5_000_000_000

      # Verify both the original and copy point to the same inode (POSIX hardlink semantics)
      assert copy_resp.node.id == original_hardlink.inode_id

      # Verify the inode is a virtual inode (streamable)
      {:ok, copy_node} = VFS.get_node(copy_resp.node.id)
      assert VFS.is_hardlink?(copy_node)

      # Verify both point to the same virtual inode (torrent_file)
      {:ok, original_node} = VFS.get_node(original_hardlink.inode_id)
      {:ok, copy_node} = VFS.get_node(copy_resp.node.id)

      {:ok, original_inode_id} = VFS.extract_virtual_inode_id(original_node)
      {:ok, copy_inode_id} = VFS.extract_virtual_inode_id(copy_node)

      assert original_inode_id == copy_inode_id
      assert original_inode_id == virtual_inode.id

      # Verify nlink count on the inode is 2 (original + copy)
      assert copy_node.nlink == 2

      # Verify external hardlink count on torrent_file increased
      hardlink_count = VFS.count_hardlinks_to_virtual_inode(virtual_inode.id)
      assert hardlink_count == 2
    end

    test "multiple copies all point to same virtual inode", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create a streamable file
      {original_hardlink, virtual_inode} =
        create_streamable_file(root_id, "series_episode.mkv", 3_000_000_000)

      # Create 5 copies
      copies =
        Enum.map(1..5, fn i ->
          {:ok, copy_resp} =
            create_link(
              channel,
              original_hardlink.inode_id,
              root_id,
              "series_episode_copy#{i}.mkv"
            )

          copy_resp.node
        end)

      # Verify all copies are streamable
      Enum.each(1..5, fn i ->
        {:ok, lookup_resp} = lookup(channel, root_id, "series_episode_copy#{i}.mkv")
        assert lookup_resp.node.streamable == true
        assert lookup_resp.node.size == 3_000_000_000
      end)

      # Verify all point to the same virtual inode
      {:ok, original_node} = VFS.get_node(original_hardlink.inode_id)
      {:ok, original_inode_id} = VFS.extract_virtual_inode_id(original_node)

      Enum.each(copies, fn copy ->
        {:ok, copy_node} = VFS.get_node(copy.id)
        {:ok, copy_inode_id} = VFS.extract_virtual_inode_id(copy_node)
        assert copy_inode_id == original_inode_id
      end)

      # Verify hardlink count is correct (original + 5 copies = 6)
      hardlink_count = VFS.count_hardlinks_to_virtual_inode(virtual_inode.id)
      assert hardlink_count == 6
    end

    test "deleting one copy doesn't affect others", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create a streamable file
      {original_hardlink, virtual_inode} =
        create_streamable_file(root_id, "movie.mkv", 4_000_000_000)

      # Create a copy
      {:ok, _copy_resp} =
        create_link(channel, original_hardlink.inode_id, root_id, "movie_copy.mkv")

      # Verify both exist and are streamable
      {:ok, original_lookup} = lookup(channel, root_id, "movie.mkv")
      assert original_lookup.node.streamable == true

      {:ok, copy_lookup} = lookup(channel, root_id, "movie_copy.mkv")
      assert copy_lookup.node.streamable == true

      # Delete the copy
      {:ok, _} = remove(channel, root_id, "movie_copy.mkv")

      # Verify the copy is gone
      assert {:ok, %{node: nil}} = lookup(channel, root_id, "movie_copy.mkv")

      # Verify the original still exists and is streamable
      {:ok, original_lookup_after} = lookup(channel, root_id, "movie.mkv")
      assert original_lookup_after.node.streamable == true
      assert original_lookup_after.node.size == 4_000_000_000

      # Verify hardlink count decreased
      hardlink_count = VFS.count_hardlinks_to_virtual_inode(virtual_inode.id)
      assert hardlink_count == 1
    end

    test "can create multiple hardlinks to the same streamable virtual inode", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create a streamable file (which is already a hardlink to a virtual inode)
      {original_hardlink, virtual_inode} =
        create_streamable_file(root_id, "video.mkv", 2_000_000_000)

      # Now we CAN create another hardlink to the virtual inode (by linking to the hardlink)
      {:ok, copy_resp} =
        create_link(channel, original_hardlink.inode_id, root_id, "video_copy.mkv")

      # Verify both are streamable and point to same virtual inode
      {:ok, original_node} = VFS.get_node(original_hardlink.inode_id)
      {:ok, copy_node} = VFS.get_node(copy_resp.node.id)

      {:ok, original_inode_id} = VFS.extract_virtual_inode_id(original_node)
      {:ok, copy_inode_id} = VFS.extract_virtual_inode_id(copy_node)

      assert original_inode_id == copy_inode_id
      assert original_inode_id == virtual_inode.id

      # Verify hardlink count increased
      hardlink_count = VFS.count_hardlinks_to_virtual_inode(virtual_inode.id)
      assert hardlink_count == 2
    end

    test "can create hardlink chain to regular POSIX hardlink (POSIX semantics)", %{
      channel: channel
    } do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create a regular file
      {:ok, _create_resp} = create_file(channel, root_id, "target.txt")
      {:ok, target_resp} = lookup(channel, root_id, "target.txt")
      target_id = target_resp.node.id

      # Write some data to it
      test_data = "test data for hardlink chain"
      {:ok, _} = write_file(channel, target_id, test_data)

      # Create a POSIX hardlink to it
      {:ok, link_resp} = create_link(channel, target_id, root_id, "link.txt")

      # Create a hardlink to the POSIX hardlink (POSIX: should succeed, links to original)
      {:ok, link_to_link_resp} =
        create_link(channel, link_resp.node.id, root_id, "link_to_link.txt")

      # All three should have the same data
      {:ok, target_data} = read_file(channel, target_id)
      {:ok, link_data} = read_file(channel, link_resp.node.id)
      {:ok, link_to_link_data} = read_file(channel, link_to_link_resp.node.id)

      assert target_data.data == test_data
      assert link_data.data == test_data
      assert link_to_link_data.data == test_data
    end

    test "copying to different directory works", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create a subdirectory
      {:ok, dir_resp} = mkdir(channel, root_id, "copies")
      dir_id = dir_resp.node.id

      # Create a streamable file in root
      {original_hardlink, virtual_inode} =
        create_streamable_file(root_id, "original.mkv", 3_500_000_000)

      # Copy to the subdirectory
      {:ok, copy_resp} =
        create_link(channel, original_hardlink.inode_id, dir_id, "original_copy.mkv")

      # Verify the copy exists in the subdirectory
      {:ok, copy_lookup} = lookup(channel, dir_id, "original_copy.mkv")
      assert copy_lookup.node.streamable == true
      assert copy_lookup.node.id == copy_resp.node.id

      # Verify both point to same virtual inode
      {:ok, original_node} = VFS.get_node(original_hardlink.inode_id)
      {:ok, copy_node} = VFS.get_node(copy_resp.node.id)

      {:ok, original_inode_id} = VFS.extract_virtual_inode_id(original_node)
      {:ok, copy_inode_id} = VFS.extract_virtual_inode_id(copy_node)

      assert original_inode_id == copy_inode_id
      assert original_inode_id == virtual_inode.id
    end
  end

  describe "Hardlink count tracking" do
    test "hardlink count tracks virtual inode references correctly", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create a streamable file
      {original_hardlink, virtual_inode} =
        create_streamable_file(root_id, "tracked.mkv", 1_000_000_000)

      # Initial count should be 1
      assert VFS.count_hardlinks_to_virtual_inode(virtual_inode.id) == 1

      # Create 3 copies
      {:ok, _copy1} =
        create_link(channel, original_hardlink.inode_id, root_id, "tracked_copy1.mkv")

      assert VFS.count_hardlinks_to_virtual_inode(virtual_inode.id) == 2

      {:ok, _copy2} =
        create_link(channel, original_hardlink.inode_id, root_id, "tracked_copy2.mkv")

      assert VFS.count_hardlinks_to_virtual_inode(virtual_inode.id) == 3

      {:ok, _copy3} =
        create_link(channel, original_hardlink.inode_id, root_id, "tracked_copy3.mkv")

      assert VFS.count_hardlinks_to_virtual_inode(virtual_inode.id) == 4

      # Delete one copy
      {:ok, _} = remove(channel, root_id, "tracked_copy2.mkv")
      assert VFS.count_hardlinks_to_virtual_inode(virtual_inode.id) == 3

      # Delete another copy
      {:ok, _} = remove(channel, root_id, "tracked_copy1.mkv")
      assert VFS.count_hardlinks_to_virtual_inode(virtual_inode.id) == 2

      # Delete all remaining copies
      {:ok, _} = remove(channel, root_id, "tracked_copy3.mkv")
      assert VFS.count_hardlinks_to_virtual_inode(virtual_inode.id) == 1

      {:ok, _} = remove(channel, root_id, "tracked.mkv")
      assert VFS.count_hardlinks_to_virtual_inode(virtual_inode.id) == 0
    end
  end

  describe "Error cases" do
    test "cannot link to non-existent node", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Try to create link to non-existent node
      assert {:error, %GRPC.RPCError{status: 5, message: "Target node not found"}} =
               create_link(channel, 999_999, root_id, "broken_link.mkv")
    end

    test "cannot link with invalid name", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create a streamable file
      {original_hardlink, _virtual_inode} =
        create_streamable_file(root_id, "valid.mkv", 1_000_000_000)

      # Try to create link with invalid name (path separator)
      assert {:error, %GRPC.RPCError{status: 3}} =
               create_link(channel, original_hardlink.inode_id, root_id, "path/to/file.mkv")
    end

    test "cannot link with duplicate name", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create a streamable file
      {original_hardlink, _virtual_inode} =
        create_streamable_file(root_id, "duplicate.mkv", 1_000_000_000)

      # Create first copy
      {:ok, _copy1} =
        create_link(channel, original_hardlink.inode_id, root_id, "duplicate_copy.mkv")

      # Try to create another copy with same name (should fail)
      assert {:error, %GRPC.RPCError{status: 3}} =
               create_link(channel, original_hardlink.inode_id, root_id, "duplicate_copy.mkv")
    end
  end
end
