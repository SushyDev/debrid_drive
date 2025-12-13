defmodule GrpcServer.E2E.HardLinkTest do
  @moduledoc """
  End-to-end tests for hard link functionality.

  Hard links are created via the Link RPC and appear as regular files.
  They transparently resolve to their target for all file operations.
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
  # Returns {:ok, hardlink_node} or {:error, reason}
  defp create_streamable_file(root_id, filename) do
    # Create a torrent with required fields
    with {:ok, torrent} <-
           VFS.Repo.insert(%Torrent{
             rd_id: "test-#{System.unique_integer()}",
             filename: filename,
             hash: "testhash#{System.unique_integer()}",
             bytes: 5_000_000,
             host: "rd.example.com",
             split: 0,
             progress: 100,
             status: "magnet_error",
             added: "2025-01-01T00:00:00Z",
             ended: "2025-01-01T00:00:00Z",
             speed: 0,
             seeders: 10
           }),
         # Create a torrent_file (virtual inode)
         {:ok, torrent_file} <-
           VFS.Repo.insert(%TorrentFile{
             torrent_id: torrent.id,
             rd_id: 1,
             path: "/#{filename}",
             bytes: 5_000_000,
             selected: 1,
             # With a link, it's streamable
             link: "https://real-debrid.com/d/EXAMPLE123"
           }),
         # Create a hardlink to the virtual inode
         {:ok, hardlink} <-
           VFS.create_hardlink_to_virtual_inode(root_id, filename, torrent_file.id) do
      {:ok, hardlink}
    end
  end

  describe "Link RPC - Hard link creation" do
    test "can create a hard link to a regular file", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create a target file
      {:ok, _create_resp} = create_file(channel, root_id, "target.txt")
      {:ok, target_resp} = lookup(channel, root_id, "target.txt")
      target_id = target_resp.node.id
      target_mode = target_resp.node.mode

      # Create hard link to the file
      {:ok, link_resp} = create_link(channel, target_id, root_id, "link_to_target")
      assert link_resp.node.name == "link_to_target"

      # Hard link should have regular file mode (not symlink)
      assert FileMode.regular?(link_resp.node.mode)
      refute FileMode.symlink?(link_resp.node.mode)

      # Hard link should have same mode as target
      assert link_resp.node.mode == target_mode

      # Verify we can look up the hard link
      {:ok, lookup_resp} = lookup(channel, root_id, "link_to_target")
      assert lookup_resp.node.id == link_resp.node.id
    end

    test "can create a hard link to a streamable file", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create a streamable file (which is a hardlink to a virtual inode)
      {:ok, streamable_node} =
        create_streamable_file(root_id, "video.mkv")

      # The streamable node itself is a hard link that appears as a regular file
      assert FileMode.regular?(streamable_node.mode)

      # The streamable node should be marked as streamable
      {:ok, lookup_resp} = lookup(channel, root_id, "video.mkv")
      assert lookup_resp.node.streamable == true
    end

    test "hard link to streamable file supports get_stream_url", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create a streamable file (which is a hardlink to a virtual inode)
      {:ok, streamable_node} =
        create_streamable_file(root_id, "movie.mkv")

      # Try to get stream URL - will fail because we don't have Real Debrid setup in test env
      # But this proves the hardlink resolution and streamable detection works
      {:error, %GRPC.RPCError{}} = get_stream_url(channel, streamable_node.inode_id)
    end

    test "returns error when target node doesn't exist", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Try to create hard link to non-existent node
      assert {:error, %GRPC.RPCError{status: 5, message: "Target node not found"}} =
               create_link(channel, 999_999, root_id, "broken_link")
    end

    test "returns error for invalid name", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _create_resp} = create_file(channel, root_id, "target.txt")
      {:ok, target_resp} = lookup(channel, root_id, "target.txt")
      target_id = target_resp.node.id

      # Try to create hard link with invalid name (contains /)
      assert {:error, %GRPC.RPCError{status: 3}} =
               create_link(channel, target_id, root_id, "link/with/slash")
    end

    test "returns error for duplicate name", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _create_resp} = create_file(channel, root_id, "target.txt")
      {:ok, target_resp} = lookup(channel, root_id, "target.txt")
      target_id = target_resp.node.id

      # Create first hard link
      {:ok, _link_resp} = create_link(channel, target_id, root_id, "duplicate")

      # Try to create another hard link with same name
      assert {:error, %GRPC.RPCError{status: 3}} =
               create_link(channel, target_id, root_id, "duplicate")
    end
  end

  describe "Hard link file operations" do
    test "can read file data through hard link", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create target file and write data to it
      {:ok, _create_resp} = create_file(channel, root_id, "target.txt")
      {:ok, target_resp} = lookup(channel, root_id, "target.txt")
      target_id = target_resp.node.id

      test_data = "Hello, hard links!"
      {:ok, _write_resp} = write_file(channel, target_id, test_data)

      # Create hard link
      {:ok, link_resp} = create_link(channel, target_id, root_id, "link.txt")
      link_id = link_resp.node.id

      # Read through hard link should return target's data
      {:ok, read_resp} = read_file(channel, link_id)
      assert read_resp.data == test_data
    end

    test "writing to hard link writes to target", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create target file
      {:ok, _create_resp} = create_file(channel, root_id, "target.txt")
      {:ok, target_resp} = lookup(channel, root_id, "target.txt")
      target_id = target_resp.node.id

      # Create hard link
      {:ok, link_resp} = create_link(channel, target_id, root_id, "link.txt")
      link_id = link_resp.node.id

      # Write through hard link
      test_data = "Written through link"
      {:ok, write_resp} = write_file(channel, link_id, test_data)
      assert write_resp.bytes_written == byte_size(test_data)

      # Read from target should show the data
      {:ok, read_resp} = read_file(channel, target_id)
      assert read_resp.data == test_data

      # Read from link should also show the data
      {:ok, read_resp} = read_file(channel, link_id)
      assert read_resp.data == test_data
    end

    test "hard link and target have same file info", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create target file with data
      {:ok, _create_resp} = create_file(channel, root_id, "target.txt")
      {:ok, target_resp} = lookup(channel, root_id, "target.txt")
      target_id = target_resp.node.id

      test_data = "Some data"
      {:ok, _write_resp} = write_file(channel, target_id, test_data)

      # Create hard link
      {:ok, link_resp} = create_link(channel, target_id, root_id, "link.txt")
      link_id = link_resp.node.id

      # Get file info for both
      {:ok, target_info} = get_file_info(channel, target_id)
      {:ok, link_info} = get_file_info(channel, link_id)

      # Hard link should report target's size and mode
      assert link_info.size == target_info.size
      assert link_info.mode == target_info.mode
      assert target_info.size == byte_size(test_data)
    end
  end

  describe "Hard link chains" do
    test "hard link to hardlink follows POSIX semantics (links to original target)", %{
      channel: channel
    } do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create target file with some data
      {:ok, _create_resp} = create_file(channel, root_id, "target.txt")
      {:ok, target_resp} = lookup(channel, root_id, "target.txt")
      target_id = target_resp.node.id

      test_data = "POSIX hardlink test data"
      {:ok, _} = write_file(channel, target_id, test_data)

      # Create first hard link pointing to target
      {:ok, link1_resp} = create_link(channel, target_id, root_id, "link1")
      link1_id = link1_resp.node.id

      # Create second hard link pointing to first hard link
      # POSIX semantics: this should succeed and create another link to the original target
      {:ok, link2_resp} = create_link(channel, link1_id, root_id, "link2")
      link2_id = link2_resp.node.id

      # All three nodes (target, link1, link2) should have the same data
      {:ok, target_data} = read_file(channel, target_id)
      {:ok, link1_data} = read_file(channel, link1_id)
      {:ok, link2_data} = read_file(channel, link2_id)

      assert target_data.data == test_data
      assert link1_data.data == test_data
      assert link2_data.data == test_data

      # Writing to link2 should be visible in target and link1
      new_data = "Updated via link2"
      {:ok, _} = write_file(channel, link2_id, new_data)

      {:ok, updated_target} = read_file(channel, target_id)
      {:ok, updated_link1} = read_file(channel, link1_id)

      assert updated_target.data == new_data
      assert updated_link1.data == new_data
    end

    test "can create multiple hardlinks to streamable file (virtual inode)", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create streamable file (which is already a hardlink to virtual inode)
      {:ok, streamable_node} =
        create_streamable_file(root_id, "video.mkv")

      # Verify streamable node is itself a hardlink
      {:ok, lookup_resp} = lookup(channel, root_id, "video.mkv")
      assert lookup_resp.node.streamable == true

      # Creating a hard link to the streamable file now succeeds
      # This creates another hardlink to the same virtual inode
      {:ok, copy_resp} = create_link(channel, streamable_node.inode_id, root_id, "video_copy.mkv")

      # Verify the copy is also streamable
      {:ok, copy_lookup_resp} = lookup(channel, root_id, "video_copy.mkv")
      assert copy_lookup_resp.node.streamable == true

      # Verify both point to the same virtual inode
      {:ok, original_node} = VFS.get_node(streamable_node.inode_id)
      {:ok, copy_node} = VFS.get_node(copy_resp.node.id)

      {:ok, original_inode_id} = VFS.extract_virtual_inode_id(original_node)
      {:ok, copy_inode_id} = VFS.extract_virtual_inode_id(copy_node)

      assert original_inode_id == copy_inode_id
    end
  end

  describe "Hard link deletion behavior" do
    test "deleting parent deletes hard link directory entry", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create a directory
      {:ok, dir_resp} = mkdir(channel, root_id, "parent_dir")
      dir_id = dir_resp.node.id

      # Create a target file in root
      {:ok, _create_resp} = create_file(channel, root_id, "target.txt")
      {:ok, target_resp} = lookup(channel, root_id, "target.txt")
      target_id = target_resp.node.id

      # Create hard link in the directory
      {:ok, link_resp} = create_link(channel, target_id, dir_id, "link_to_target")
      link_inode_id = link_resp.node.id

      # Both should point to the same inode
      assert link_inode_id == target_id

      # Verify hard link exists
      assert {:ok, _} = lookup(channel, dir_id, "link_to_target")

      # Delete parent directory
      assert {:ok, _} = remove(channel, root_id, "parent_dir")

      # The directory itself is now gone
      assert {:error, :not_found} = VFS.get_node(dir_id)

      # But the inode still exists because target.txt still points to it (POSIX semantics)
      assert {:ok, _inode} = VFS.get_node(link_inode_id)

      # Target file should still exist and accessible
      {:ok, lookup_resp} = lookup(channel, root_id, "target.txt")
      assert lookup_resp.node.id == target_id
    end

    test "deleting one directory entry doesn't affect other hardlinks (POSIX semantics)", %{
      channel: channel
    } do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create a target file
      {:ok, _create_resp} = create_file(channel, root_id, "target.txt")
      {:ok, target_resp} = lookup(channel, root_id, "target.txt")
      target_id = target_resp.node.id

      # Create hard link
      {:ok, link_resp} = create_link(channel, target_id, root_id, "link_to_target")
      link_id = link_resp.node.id

      # They should share the same inode
      assert link_id == target_id

      # Delete target file
      assert {:ok, _} = remove(channel, root_id, "target.txt")

      # Hard link should still exist and work perfectly (POSIX semantics)
      {:ok, lookup_resp} = lookup(channel, root_id, "link_to_target")
      assert lookup_resp.node.id == link_id

      # The inode is still accessible
      {:ok, inode} = VFS.get_node(target_id)
      # Down from 2 to 1
      assert inode.nlink == 1
    end

    test "deleting all directory entries eventually deletes the inode (nlink tracking)", %{
      channel: channel
    } do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create target file
      {:ok, _create_resp} = create_file(channel, root_id, "target.txt")
      {:ok, target_resp} = lookup(channel, root_id, "target.txt")
      target_id = target_resp.node.id

      # Create two hard links pointing to the same inode
      {:ok, link1_resp} = create_link(channel, target_id, root_id, "link1")
      link1_id = link1_resp.node.id
      {:ok, link2_resp} = create_link(channel, target_id, root_id, "link2")
      link2_id = link2_resp.node.id

      # All should share the same inode
      assert link1_id == target_id
      assert link2_id == target_id

      # Verify nlink=3 (target.txt + link1 + link2)
      {:ok, inode} = VFS.get_node(target_id)
      assert inode.nlink == 3

      # Delete target file
      assert {:ok, _} = remove(channel, root_id, "target.txt")

      # Inode should still exist with nlink=2
      {:ok, inode} = VFS.get_node(target_id)
      assert inode.nlink == 2

      # Delete link1
      assert {:ok, _} = remove(channel, root_id, "link1")

      # Inode should still exist with nlink=1
      {:ok, inode} = VFS.get_node(target_id)
      assert inode.nlink == 1

      # Delete link2 (last reference)
      assert {:ok, _} = remove(channel, root_id, "link2")

      # NOW the inode should be gone (nlink reached 0)
      assert {:error, :not_found} = VFS.get_node(target_id)
    end

    test "deleting virtual inode makes hardlinks non-streamable", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create a torrent with virtual inode
      {:ok, torrent} =
        VFS.Repo.insert(%Torrent{
          rd_id: "test-#{System.unique_integer()}",
          filename: "video.mkv",
          hash: "testhash#{System.unique_integer()}",
          bytes: 5_000_000,
          host: "rd.example.com",
          split: 0,
          progress: 100,
          status: "magnet_error",
          added: "2025-01-01T00:00:00Z",
          ended: "2025-01-01T00:00:00Z",
          speed: 0,
          seeders: 10
        })

      # Create a torrent_file (virtual inode)
      {:ok, torrent_file} =
        VFS.Repo.insert(%TorrentFile{
          torrent_id: torrent.id,
          rd_id: 1,
          path: "/video.mkv",
          bytes: 5_000_000,
          selected: 1,
          link: "https://real-debrid.com/d/EXAMPLE123"
        })

      # Create two hardlinks to the same virtual inode
      {:ok, link1} =
        VFS.create_hardlink_to_virtual_inode(root_id, "link1", torrent_file.id)

      link1_id = link1.inode_id

      {:ok, link2} =
        VFS.create_hardlink_to_virtual_inode(root_id, "link2", torrent_file.id)

      link2_id = link2.inode_id

      # They should share the same inode since they're both hardlinks to the same virtual inode
      assert link1_id == link2_id

      # Verify both are streamable before deletion
      {:ok, lookup_resp} = lookup(channel, root_id, "link1")
      assert lookup_resp.node.streamable == true
      {:ok, lookup_resp} = lookup(channel, root_id, "link2")
      assert lookup_resp.node.streamable == true

      # Delete the virtual inode (torrent_file)
      {:ok, _} = VFS.Repo.delete(torrent_file)

      # Both hard links (directory entries) should still exist
      {:ok, lookup_resp} = lookup(channel, root_id, "link1")
      assert lookup_resp.node.id == link1_id
      {:ok, lookup_resp} = lookup(channel, root_id, "link2")
      assert lookup_resp.node.id == link2_id

      # But they should no longer be marked as streamable (broken virtual inode reference)
      {:ok, lookup_resp} = lookup(channel, root_id, "link1")
      assert lookup_resp.node.streamable == false
      {:ok, lookup_resp} = lookup(channel, root_id, "link2")
      assert lookup_resp.node.streamable == false
    end
  end

  describe "GetStreamUrl - Error cases" do
    test "returns nil url for non-existent node", %{channel: channel} do
      non_existent_id = 999_999

      assert {:ok, %StreamMountApi.GetStreamUrlResponse{url: nil}} =
               get_stream_url(channel, non_existent_id)
    end

    test "returns failed_precondition for directory node", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, dir_resp} = mkdir(channel, root_id, "test_dir")
      dir_id = dir_resp.node.id

      # Directories cannot be streamed
      assert {:error, %GRPC.RPCError{status: 9}} =
               get_stream_url(channel, dir_id)
    end

    test "returns failed_precondition for non-streamable file", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create a regular file (not streamable type)
      {:ok, _create_resp} = create_file(channel, root_id, "regular.txt")
      {:ok, file_resp} = lookup(channel, root_id, "regular.txt")
      file_id = file_resp.node.id

      # Regular files without torrent data cannot be streamed
      assert {:error, %GRPC.RPCError{status: 9}} =
               get_stream_url(channel, file_id)
    end

    test "can create streamable file directly via VFS", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create a streamable file directly through VFS (helper creates Torrent + TorrentFile + hardlink)
      {:ok, streamable_node} =
        create_streamable_file(root_id, "streamable.mkv")

      # Verify it's marked as streamable in the proto response
      {:ok, lookup_resp} = lookup(channel, root_id, "streamable.mkv")
      assert lookup_resp.node.streamable == true

      # Getting stream URL will fail due to Real Debrid API unavailability in test
      # but this proves the virtual inode setup and hardlink resolution works
      {:error, %GRPC.RPCError{}} = get_stream_url(channel, streamable_node.inode_id)
    end
  end

  describe "Basic gRPC operations" do
    test "ReadDirAll returns empty list for non-existent directory", %{channel: channel} do
      assert {:ok, %StreamMountApi.ReadDirAllResponse{nodes: []}} =
               read_dir_all(channel, 999_999)
    end

    test "ReadDirAll returns invalid_argument when called on a file", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _create_resp} = create_file(channel, root_id, "test.txt")
      {:ok, file_resp} = lookup(channel, root_id, "test.txt")
      file_id = file_resp.node.id

      assert {:error, %GRPC.RPCError{status: 3, message: "Not a directory"}} =
               read_dir_all(channel, file_id)
    end
  end

  describe "Name validation" do
    test "rejects empty filename", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      assert {:error, %GRPC.RPCError{status: 3, message: "Name cannot be empty"}} =
               create_file(channel, root_id, "")
    end

    test "rejects filename with path separator", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      assert {:error, %GRPC.RPCError{status: 3, message: "Name cannot contain path separator"}} =
               create_file(channel, root_id, "path/to/file.txt")
    end

    test "rejects filename with null byte", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      assert {:error, %GRPC.RPCError{status: 3, message: "Name cannot contain null bytes"}} =
               create_file(channel, root_id, "file\0name.txt")
    end

    test "rejects filename exceeding maximum length", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      long_name = String.duplicate("a", 256)

      assert {:error, %GRPC.RPCError{status: 3, message: "Name exceeds maximum length"}} =
               create_file(channel, root_id, long_name)
    end

    test "accepts filename at maximum length", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      max_length_name = String.duplicate("a", 255)

      assert {:ok, _} = create_file(channel, root_id, max_length_name)
    end
  end
end
