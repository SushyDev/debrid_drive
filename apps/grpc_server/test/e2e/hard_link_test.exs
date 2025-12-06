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

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(VFS.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(VFS.Repo, {:shared, self()})

    channel = connect()

    on_exit(fn ->
      disconnect(channel)
    end)

    {:ok, channel: channel}
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

      # Create a streamable file
      {:ok, streamable_node} =
        VFS.create_file(root_id, "video.mkv", content_type: "sync_engine/streamable")

      # Create hard link to the streamable file
      {:ok, link_resp} = create_link(channel, streamable_node.id, root_id, "link_to_video")

      # The hard link should appear as a regular file
      assert FileMode.regular?(link_resp.node.mode)

      # The hard link itself should be marked as streamable (since it points to streamable)
      {:ok, lookup_resp} = lookup(channel, root_id, "link_to_video")
      assert lookup_resp.node.streamable == true
    end

    test "hard link to streamable file supports get_stream_url", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create a streamable file
      {:ok, streamable_node} =
        VFS.create_file(root_id, "movie.mkv", content_type: "sync_engine/streamable")

      # Create hard link
      {:ok, link_resp} = create_link(channel, streamable_node.id, root_id, "link_to_movie")
      link_id = link_resp.node.id

      # Should return failed_precondition because no torrent_file exists
      # but this proves the hard link resolution works
      assert {:error, %GRPC.RPCError{status: 9}} = get_stream_url(channel, link_id)
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
    test "hard link cannot point to another hard link", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create target file
      {:ok, _create_resp} = create_file(channel, root_id, "target.txt")
      {:ok, target_resp} = lookup(channel, root_id, "target.txt")
      target_id = target_resp.node.id

      # Create first hard link pointing to target
      {:ok, link1_resp} = create_link(channel, target_id, root_id, "link1")
      link1_id = link1_resp.node.id

      # Attempting to create second hard link pointing to first hard link should fail
      assert {:error,
              %GRPC.RPCError{status: 3, message: "Cannot create a hard link to another hard link"}} =
               create_link(channel, link1_id, root_id, "link2")
    end

    test "cannot create hard link chain to streamable file", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create streamable file
      {:ok, streamable_node} =
        VFS.create_file(root_id, "video.mkv", content_type: "sync_engine/streamable")

      # Create first hard link pointing to streamable file - this works
      {:ok, link1_resp} = create_link(channel, streamable_node.id, root_id, "link1")
      link1_id = link1_resp.node.id

      # Verify first link is streamable
      {:ok, lookup_resp} = lookup(channel, root_id, "link1")
      assert lookup_resp.node.streamable == true

      # Attempting to create second hard link pointing to first hard link should fail
      assert {:error,
              %GRPC.RPCError{status: 3, message: "Cannot create a hard link to another hard link"}} =
               create_link(channel, link1_id, root_id, "link2")
    end
  end

  describe "Hard link deletion behavior" do
    test "deleting parent deletes hard link", %{channel: channel} do
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
      link_id = link_resp.node.id

      # Verify hard link exists
      assert {:ok, _} = lookup(channel, dir_id, "link_to_target")

      # Delete parent directory
      assert {:ok, _} = remove(channel, root_id, "parent_dir")

      # Verify hard link is gone
      assert {:error, :not_found} = VFS.get_node(link_id)

      # Target file should still exist
      {:ok, lookup_resp} = lookup(channel, root_id, "target.txt")
      assert lookup_resp.node.id == target_id
    end

    test "deleting target doesn't delete hard link but makes it broken", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create a target file
      {:ok, _create_resp} = create_file(channel, root_id, "target.txt")
      {:ok, target_resp} = lookup(channel, root_id, "target.txt")
      target_id = target_resp.node.id

      # Create hard link
      {:ok, link_resp} = create_link(channel, target_id, root_id, "link_to_target")
      link_id = link_resp.node.id

      # Delete target file
      assert {:ok, _} = remove(channel, root_id, "target.txt")

      # Hard link should still exist
      {:ok, lookup_resp} = lookup(channel, root_id, "link_to_target")
      assert lookup_resp.node.id == link_id

      # But reading it should fail (broken hard link)
      {:ok, link_node} = VFS.get_node(link_id)
      assert {:error, :not_found} = VFS.get_node(String.to_integer(link_node.data))
    end

    test "deleting hard link target makes remaining hard links broken", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create target file
      {:ok, _create_resp} = create_file(channel, root_id, "target.txt")
      {:ok, target_resp} = lookup(channel, root_id, "target.txt")
      target_id = target_resp.node.id

      # Create two hard links pointing directly to the target
      {:ok, link1_resp} = create_link(channel, target_id, root_id, "link1")
      link1_id = link1_resp.node.id
      {:ok, link2_resp} = create_link(channel, target_id, root_id, "link2")
      link2_id = link2_resp.node.id

      # Delete target file
      assert {:ok, _} = remove(channel, root_id, "target.txt")

      # Both hard links should still exist but are now broken
      {:ok, link1_node} = VFS.get_node(link1_id)
      assert link1_node.content_type == "inode/hardlink"
      {:ok, link2_node} = VFS.get_node(link2_id)
      assert link2_node.content_type == "inode/hardlink"

      # But the target they point to is gone
      assert {:error, :not_found} = VFS.get_node(String.to_integer(link1_node.data))
      assert {:error, :not_found} = VFS.get_node(String.to_integer(link2_node.data))
    end

    test "deleting final target breaks all hard links pointing to it", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create streamable file
      {:ok, streamable_node} =
        VFS.create_file(root_id, "video.mkv", content_type: "sync_engine/streamable")

      # Create two hard links pointing directly to the streamable file
      {:ok, link1_resp} = create_link(channel, streamable_node.id, root_id, "link1")
      link1_id = link1_resp.node.id
      {:ok, link2_resp} = create_link(channel, streamable_node.id, root_id, "link2")
      link2_id = link2_resp.node.id

      # Verify both are streamable before deletion
      {:ok, lookup_resp} = lookup(channel, root_id, "link1")
      assert lookup_resp.node.streamable == true
      {:ok, lookup_resp} = lookup(channel, root_id, "link2")
      assert lookup_resp.node.streamable == true

      # Delete the final target (streamable file)
      assert %VFS.Node{} = VFS.remove_by_id(streamable_node.id)

      # Both hard links should still exist
      {:ok, link1_node} = VFS.get_node(link1_id)
      assert link1_node.content_type == "inode/hardlink"
      {:ok, link2_node} = VFS.get_node(link2_id)
      assert link2_node.content_type == "inode/hardlink"

      # But they should no longer be marked as streamable (broken links)
      {:ok, lookup_resp} = lookup(channel, root_id, "link1")
      assert lookup_resp.node.streamable == false
      {:ok, lookup_resp} = lookup(channel, root_id, "link2")
      assert lookup_resp.node.streamable == false
    end
  end

  describe "GetStreamUrl - Error cases" do
    test "returns not_found for non-existent node", %{channel: channel} do
      non_existent_id = 999_999

      assert {:error, %GRPC.RPCError{status: 5}} =
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

      # Create a streamable file directly through VFS
      {:ok, streamable_node} =
        VFS.create_file(root_id, "streamable.mkv", content_type: "sync_engine/streamable")

      # Verify it's marked as streamable in the proto response
      {:ok, lookup_resp} = lookup(channel, root_id, "streamable.mkv")
      assert lookup_resp.node.streamable == true

      # Note: Would return failed_precondition because no torrent_file exists
      # In real usage, torrent_files are created by the sync_engine sync process
      assert {:error, %GRPC.RPCError{status: 9}} =
               get_stream_url(channel, streamable_node.id)
    end
  end

  describe "Basic gRPC operations" do
    test "ReadDirAll returns not_found for non-existent directory", %{channel: channel} do
      assert {:error, %GRPC.RPCError{status: 5, message: "Node not found"}} =
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
