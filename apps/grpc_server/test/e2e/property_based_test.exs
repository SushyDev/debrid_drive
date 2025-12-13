defmodule GrpcServer.E2E.PropertyBasedTest do
  @moduledoc """
  Property-based tests for filesystem operations.
  Uses StreamData to generate random test scenarios and verify invariants.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  import GrpcServer.Test.GrpcClientHelper

  setup do
    :ok = GrpcTestHelper.cleanup_database()

    :ok = GrpcTestHelper.wait_for_db_ready()

    channel = connect()

    on_exit(fn ->
      disconnect(channel)
    end)

    {:ok, channel: channel}
  end

  # Generators

  defp valid_filename do
    # Generate valid filenames (alphanumeric, dots, underscores, hyphens)
    gen all(
          base <- string(:alphanumeric, min_length: 1, max_length: 20),
          ext <- one_of([constant(""), string(:alphanumeric, min_length: 1, max_length: 4)])
        ) do
      if ext == "", do: base, else: "#{base}.#{ext}"
    end
  end

  defp file_content do
    # Generate various file contents
    one_of([
      binary(min_length: 0, max_length: 1000),
      string(:printable, min_length: 0, max_length: 500)
    ])
  end

  describe "Property: Write-then-read returns same data" do
    property "any data written to a file can be read back identically", %{channel: channel} do
      check all(
              filename <- valid_filename(),
              content <- file_content()
            ) do
        {:ok, root_resp} = get_root(channel)
        root_id = root_resp.root.id

        # Create file
        {:ok, _} = create_file(channel, root_id, filename)
        {:ok, lookup_resp} = lookup(channel, root_id, filename)
        file_id = lookup_resp.node.id

        # Write content
        {:ok, _} = write_file(channel, file_id, content)

        # Read back
        {:ok, read_resp} = read_file(channel, file_id)

        # Property: content should match
        assert read_resp.data == content
      end
    end
  end

  describe "Property: File operations maintain consistency" do
    property "creating and immediately looking up a file always succeeds", %{channel: channel} do
      check all(filename <- valid_filename()) do
        {:ok, root_resp} = get_root(channel)
        root_id = root_resp.root.id

        # Create
        {:ok, _} = create_file(channel, root_id, filename)

        # Lookup should succeed
        {:ok, lookup_resp} = lookup(channel, root_id, filename)

        # Property: looked up node has the correct name
        assert lookup_resp.node.name == filename
      end
    end

    property "file size matches content length after write", %{channel: channel} do
      check all(
              filename <- valid_filename(),
              content <- file_content()
            ) do
        {:ok, root_resp} = get_root(channel)
        root_id = root_resp.root.id

        {:ok, _} = create_file(channel, root_id, filename)
        {:ok, lookup_resp} = lookup(channel, root_id, filename)
        file_id = lookup_resp.node.id

        {:ok, _} = write_file(channel, file_id, content)

        {:ok, info_resp} = get_file_info(channel, file_id)

        # Property: size should match content length
        assert info_resp.size == byte_size(content)
      end
    end

    property "removing a file makes it unfindable", %{channel: channel} do
      check all(filename <- valid_filename()) do
        {:ok, root_resp} = get_root(channel)
        root_id = root_resp.root.id

        {:ok, _} = create_file(channel, root_id, filename)
        {:ok, _} = remove(channel, root_id, filename)

        # Property: lookup should return empty response (FUSE ENOENT behavior)
        {:ok, lookup_resp} = lookup(channel, root_id, filename)
        assert lookup_resp.node == nil
      end
    end
  end

  describe "Property: Directory listing consistency" do
    property "creating N files results in N entries in directory", %{channel: channel} do
      check all(
              num_files <- integer(1..20),
              # Generate unique filenames
              max_runs: 50
            ) do
        {:ok, root_resp} = get_root(channel)
        root_id = root_resp.root.id

        # Create a test directory
        test_dir_name = "proptest_#{:erlang.unique_integer([:positive])}"
        {:ok, dir_resp} = mkdir(channel, root_id, test_dir_name)
        dir_id = dir_resp.node.id

        # Create N files
        Enum.each(1..num_files, fn i ->
          filename = "file_#{i}.txt"
          {:ok, _} = create_file(channel, dir_id, filename)
        end)

        # List directory
        {:ok, list_resp} = read_dir_all(channel, dir_id)

        # Property: should have exactly N files
        assert length(list_resp.nodes) == num_files
      end
    end

    property "all created items appear in directory listing", %{channel: channel} do
      check all(filenames <- uniq_list_of(valid_filename(), min_length: 1, max_length: 15)) do
        {:ok, root_resp} = get_root(channel)
        root_id = root_resp.root.id

        # Create test directory
        test_dir_name = "listtest_#{:erlang.unique_integer([:positive])}"
        {:ok, dir_resp} = mkdir(channel, root_id, test_dir_name)
        dir_id = dir_resp.node.id

        # Create files
        Enum.each(filenames, fn filename ->
          {:ok, _} = create_file(channel, dir_id, filename)
        end)

        # List directory
        {:ok, list_resp} = read_dir_all(channel, dir_id)
        listed_names = Enum.map(list_resp.nodes, & &1.name) |> Enum.sort()

        # Property: all created filenames should appear in listing
        assert listed_names == Enum.sort(filenames)
      end
    end
  end

  describe "Property: Rename operations" do
    property "renaming preserves file content", %{channel: channel} do
      check all(
              old_name <- valid_filename(),
              new_name <- valid_filename(),
              content <- file_content(),
              old_name != new_name
            ) do
        {:ok, root_resp} = get_root(channel)
        root_id = root_resp.root.id

        # Create directory for test
        test_dir = "rename_#{:erlang.unique_integer([:positive])}"
        {:ok, dir_resp} = mkdir(channel, root_id, test_dir)
        dir_id = dir_resp.node.id

        # Create file and write content
        {:ok, _} = create_file(channel, dir_id, old_name)
        {:ok, lookup_resp} = lookup(channel, dir_id, old_name)
        file_id = lookup_resp.node.id
        {:ok, _} = write_file(channel, file_id, content)

        # Rename
        {:ok, rename_resp} = rename(channel, dir_id, old_name, dir_id, new_name)
        new_id = rename_resp.node.id

        # Read content from renamed file
        {:ok, read_resp} = read_file(channel, new_id)

        # Property: content should be preserved
        assert read_resp.data == content
      end
    end

    property "after rename, old name is gone and new name exists", %{channel: channel} do
      check all(
              old_name <- valid_filename(),
              new_name <- valid_filename(),
              old_name != new_name
            ) do
        {:ok, root_resp} = get_root(channel)
        root_id = root_resp.root.id

        # Create directory for test
        test_dir = "rename2_#{:erlang.unique_integer([:positive])}"
        {:ok, dir_resp} = mkdir(channel, root_id, test_dir)
        dir_id = dir_resp.node.id

        {:ok, _} = create_file(channel, dir_id, old_name)
        {:ok, _} = rename(channel, dir_id, old_name, dir_id, new_name)

        # Property: old name should not exist (FUSE ENOENT behavior)
        {:ok, old_lookup_resp} = lookup(channel, dir_id, old_name)
        assert old_lookup_resp.node == nil

        # Property: new name should exist
        {:ok, lookup_resp} = lookup(channel, dir_id, new_name)
        assert lookup_resp.node.name == new_name
      end
    end
  end

  describe "Property: Partial read operations" do
    property "reading with offset and size returns correct substring", %{channel: channel} do
      check all(
              filename <- valid_filename(),
              # Generate content with minimum length to ensure valid offsets
              content <- binary(min_length: 10, max_length: 100),
              offset <- integer(0..9),
              size <- integer(1..10)
            ) do
        {:ok, root_resp} = get_root(channel)
        root_id = root_resp.root.id

        {:ok, _} = create_file(channel, root_id, filename)
        {:ok, lookup_resp} = lookup(channel, root_id, filename)
        file_id = lookup_resp.node.id

        {:ok, _} = write_file(channel, file_id, content)

        # Read partial
        {:ok, read_resp} = read_file(channel, file_id, offset, size)

        # Calculate expected result
        expected_size = min(size, byte_size(content) - offset)
        expected_data = binary_part(content, offset, expected_size)

        # Property: should get the correct slice
        assert read_resp.data == expected_data
      end
    end
  end

  describe "Property: Multiple writes to same file" do
    property "last write wins when overwriting entire file", %{channel: channel} do
      check all(
              filename <- valid_filename(),
              writes <- list_of(file_content(), min_length: 2, max_length: 10)
            ) do
        {:ok, root_resp} = get_root(channel)
        root_id = root_resp.root.id

        {:ok, _} = create_file(channel, root_id, filename)
        {:ok, lookup_resp} = lookup(channel, root_id, filename)
        file_id = lookup_resp.node.id

        # Perform multiple writes
        Enum.each(writes, fn content ->
          {:ok, _} = write_file(channel, file_id, content)
        end)

        # Read final content
        {:ok, read_resp} = read_file(channel, file_id)

        # Property: should have the last written content
        last_content = List.last(writes)
        assert read_resp.data == last_content
      end
    end
  end

  describe "Property: Empty operations" do
    property "writing empty data creates zero-size file", %{channel: channel} do
      check all(filename <- valid_filename()) do
        {:ok, root_resp} = get_root(channel)
        root_id = root_resp.root.id

        {:ok, _} = create_file(channel, root_id, filename)
        {:ok, lookup_resp} = lookup(channel, root_id, filename)
        file_id = lookup_resp.node.id

        {:ok, _} = write_file(channel, file_id, "")

        {:ok, info_resp} = get_file_info(channel, file_id)

        # Property: size should be 0
        assert info_resp.size == 0
      end
    end

    property "reading empty file returns empty data", %{channel: channel} do
      check all(filename <- valid_filename()) do
        {:ok, root_resp} = get_root(channel)
        root_id = root_resp.root.id

        {:ok, _} = create_file(channel, root_id, filename)
        {:ok, lookup_resp} = lookup(channel, root_id, filename)
        file_id = lookup_resp.node.id

        # Don't write anything, just read
        {:ok, read_resp} = read_file(channel, file_id)

        # Property: should get empty binary
        assert read_resp.data == <<>>
      end
    end
  end
end
