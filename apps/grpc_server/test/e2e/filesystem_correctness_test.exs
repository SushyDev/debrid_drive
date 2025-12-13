defmodule GrpcServer.E2E.FilesystemCorrectnessTest do
  @moduledoc """
  End-to-end tests for filesystem correctness.
  Tests basic filesystem operations through the gRPC interface.
  """
  use ExUnit.Case, async: false

  import GrpcServer.Test.GrpcClientHelper

  alias VFS

  setup do
    :ok = GrpcTestHelper.cleanup_database()

    :ok = GrpcTestHelper.wait_for_db_ready()

    # Connect to gRPC server (assumes server is running)
    channel = connect()

    # Clean up function
    on_exit(fn ->
      disconnect(channel)
    end)

    {:ok, channel: channel}
  end

  describe "Root operations" do
    test "can get root node", %{channel: channel} do
      assert {:ok, response} = get_root(channel)
      assert response.root != nil
      assert response.root.name == "/"
      assert response.root.id > 0
    end

    test "root node is consistent across calls", %{channel: channel} do
      {:ok, response1} = get_root(channel)
      {:ok, response2} = get_root(channel)

      assert response1.root.id == response2.root.id
      assert response1.root.name == response2.root.name
    end
  end

  describe "Directory operations" do
    test "can create a directory", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      assert {:ok, response} = mkdir(channel, root_id, "test_dir")
      assert response.node.name == "test_dir"
      assert response.node.id > 0
    end

    test "can create nested directories", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, dir1} = mkdir(channel, root_id, "dir1")
      {:ok, dir2} = mkdir(channel, dir1.node.id, "dir2")
      {:ok, dir3} = mkdir(channel, dir2.node.id, "dir3")

      assert dir3.node.name == "dir3"
    end

    test "can list directory contents", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create multiple directories
      {:ok, _} = mkdir(channel, root_id, "dir_a")
      {:ok, _} = mkdir(channel, root_id, "dir_b")
      {:ok, _} = mkdir(channel, root_id, "dir_c")

      {:ok, list_resp} = read_dir_all(channel, root_id)
      names = Enum.map(list_resp.nodes, & &1.name) |> Enum.sort()

      assert names == ["dir_a", "dir_b", "dir_c"]
    end

    test "can lookup directory by name", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, mkdir_resp} = mkdir(channel, root_id, "lookup_test")
      created_id = mkdir_resp.node.id

      {:ok, lookup_resp} = lookup(channel, root_id, "lookup_test")

      assert lookup_resp.node.id == created_id
      assert lookup_resp.node.name == "lookup_test"
    end

    test "lookup returns nil node for non-existent directory", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      assert {:ok, %StreamMountApi.LookupResponse{node: nil}} =
               lookup(channel, root_id, "non_existent")
    end
  end

  describe "File operations" do
    test "can create a file", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      assert {:ok, _response} = create_file(channel, root_id, "test.txt")
    end

    test "can write and read file data", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create file
      {:ok, _} = create_file(channel, root_id, "data.txt")

      # Lookup to get node ID
      {:ok, lookup_resp} = lookup(channel, root_id, "data.txt")
      file_id = lookup_resp.node.id

      # Write data
      content = "Hello, World!"
      {:ok, write_resp} = write_file(channel, file_id, content)
      assert write_resp.bytes_written == byte_size(content)

      # Read data back
      {:ok, read_resp} = read_file(channel, file_id)
      assert read_resp.data == content
    end

    test "can write data at offset", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "offset.txt")
      {:ok, lookup_resp} = lookup(channel, root_id, "offset.txt")
      file_id = lookup_resp.node.id

      # Write initial data
      {:ok, _} = write_file(channel, file_id, "Hello")

      # Write at offset
      {:ok, _} = write_file(channel, file_id, " World", 5)

      # Read back
      {:ok, read_resp} = read_file(channel, file_id)
      assert read_resp.data == "Hello World"
    end

    test "can read partial file data", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "partial.txt")
      {:ok, lookup_resp} = lookup(channel, root_id, "partial.txt")
      file_id = lookup_resp.node.id

      content = "0123456789"
      {:ok, _} = write_file(channel, file_id, content)

      # Read with offset and size
      {:ok, read_resp} = read_file(channel, file_id, 2, 5)
      assert read_resp.data == "23456"
    end

    test "can get file info", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "info.txt")
      {:ok, lookup_resp} = lookup(channel, root_id, "info.txt")
      file_id = lookup_resp.node.id

      content = "Test content"
      {:ok, _} = write_file(channel, file_id, content)

      {:ok, info_resp} = get_file_info(channel, file_id)
      assert info_resp.size == byte_size(content)
      assert info_resp.mode > 0
    end

    test "empty file has size 0", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "empty.txt")
      {:ok, lookup_resp} = lookup(channel, root_id, "empty.txt")
      file_id = lookup_resp.node.id

      {:ok, info_resp} = get_file_info(channel, file_id)
      assert info_resp.size == 0
    end
  end

  describe "Remove operations" do
    test "can remove a file", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "to_remove.txt")
      {:ok, _} = remove(channel, root_id, "to_remove.txt")

      # Verify file is gone
      assert {:ok, %StreamMountApi.LookupResponse{node: nil}} =
               lookup(channel, root_id, "to_remove.txt")
    end

    test "can remove a directory", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = mkdir(channel, root_id, "to_remove_dir")
      {:ok, _} = remove(channel, root_id, "to_remove_dir")

      assert {:ok, %StreamMountApi.LookupResponse{node: nil}} =
               lookup(channel, root_id, "to_remove_dir")
    end

    test "removing non-existent file returns error", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      assert {:error, %GRPC.RPCError{status: 5}} =
               remove(channel, root_id, "does_not_exist.txt")
    end
  end

  describe "Rename/Move operations" do
    test "can rename a file", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "old_name.txt")
      {:ok, _} = rename(channel, root_id, "old_name.txt", root_id, "new_name.txt")

      # Old name should not exist
      assert {:ok, %StreamMountApi.LookupResponse{node: nil}} =
               lookup(channel, root_id, "old_name.txt")

      # New name should exist
      {:ok, lookup_resp} = lookup(channel, root_id, "new_name.txt")
      assert lookup_resp.node.name == "new_name.txt"
    end

    test "can move file to different directory", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "moveme.txt")
      {:ok, dir_resp} = mkdir(channel, root_id, "target_dir")
      target_id = dir_resp.node.id

      {:ok, _} = rename(channel, root_id, "moveme.txt", target_id, "moveme.txt")

      # Should not be in root anymore
      assert {:ok, %StreamMountApi.LookupResponse{node: nil}} =
               lookup(channel, root_id, "moveme.txt")

      # Should be in target directory
      {:ok, lookup_resp} = lookup(channel, target_id, "moveme.txt")
      assert lookup_resp.node.name == "moveme.txt"
    end

    test "rename preserves file content", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "content.txt")
      {:ok, lookup_resp} = lookup(channel, root_id, "content.txt")
      file_id = lookup_resp.node.id

      content = "Important data"
      {:ok, _} = write_file(channel, file_id, content)

      # Rename
      {:ok, rename_resp} = rename(channel, root_id, "content.txt", root_id, "renamed.txt")
      renamed_id = rename_resp.node.id

      # Read content from renamed file
      {:ok, read_resp} = read_file(channel, renamed_id)
      assert read_resp.data == content
    end
  end

  describe "Data integrity" do
    test "writing multiple times overwrites data", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "overwrite.txt")
      {:ok, lookup_resp} = lookup(channel, root_id, "overwrite.txt")
      file_id = lookup_resp.node.id

      {:ok, _} = write_file(channel, file_id, "First")
      {:ok, _} = write_file(channel, file_id, "Second")

      {:ok, read_resp} = read_file(channel, file_id)
      assert read_resp.data == "Second"
    end

    test "binary data is preserved correctly", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "binary.dat")
      {:ok, lookup_resp} = lookup(channel, root_id, "binary.dat")
      file_id = lookup_resp.node.id

      # Write binary data with null bytes
      binary_data = <<0, 1, 2, 255, 254, 253, 0, 0, 123>>
      {:ok, _} = write_file(channel, file_id, binary_data)

      {:ok, read_resp} = read_file(channel, file_id)
      assert read_resp.data == binary_data
    end

    test "large text data is preserved", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "large.txt")
      {:ok, lookup_resp} = lookup(channel, root_id, "large.txt")
      file_id = lookup_resp.node.id

      # Generate large content
      large_content = String.duplicate("Hello World! ", 1000)
      {:ok, _} = write_file(channel, file_id, large_content)

      {:ok, read_resp} = read_file(channel, file_id)
      assert read_resp.data == large_content
      assert byte_size(read_resp.data) == byte_size(large_content)
    end
  end
end
