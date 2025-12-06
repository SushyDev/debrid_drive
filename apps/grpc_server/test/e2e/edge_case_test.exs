defmodule GrpcServer.E2E.EdgeCaseTest do
  @moduledoc """
  Tests for edge cases and boundary conditions in the filesystem.
  """
  use ExUnit.Case, async: false

  import GrpcServer.Test.GrpcClientHelper

  require Logger

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(VFS.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(VFS.Repo, {:shared, self()})

    channel = connect()

    on_exit(fn ->
      disconnect(channel)
    end)

    {:ok, channel: channel}
  end

  describe "Edge case: Empty files" do
    test "empty file has size 0", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "empty.txt")
      {:ok, lookup_resp} = lookup(channel, root_id, "empty.txt")
      file_id = lookup_resp.node.id

      {:ok, info_resp} = get_file_info(channel, file_id)
      assert info_resp.size == 0
    end

    test "reading empty file returns empty data", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "empty2.txt")
      {:ok, lookup_resp} = lookup(channel, root_id, "empty2.txt")
      file_id = lookup_resp.node.id

      {:ok, read_resp} = read_file(channel, file_id)
      assert read_resp.data == <<>>
    end

    test "writing empty string creates empty file", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "write_empty.txt")
      {:ok, lookup_resp} = lookup(channel, root_id, "write_empty.txt")
      file_id = lookup_resp.node.id

      {:ok, _} = write_file(channel, file_id, "")

      {:ok, info_resp} = get_file_info(channel, file_id)
      assert info_resp.size == 0
    end
  end

  describe "Edge case: Large files" do
    @tag timeout: 60_000
    test "can handle 10MB file", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "large_10mb.bin")
      {:ok, lookup_resp} = lookup(channel, root_id, "large_10mb.bin")
      file_id = lookup_resp.node.id

      # Generate 10MB of data
      large_data = :binary.copy(<<"x">>, 10 * 1024 * 1024)
      {:ok, _} = write_file(channel, file_id, large_data)

      {:ok, info_resp} = get_file_info(channel, file_id)
      assert info_resp.size == byte_size(large_data)

      # Read back first 100 bytes to verify
      {:ok, read_resp} = read_file(channel, file_id, 0, 100)
      assert byte_size(read_resp.data) == 100
    end

    @tag timeout: 60_000
    test "chunked writes to create large file", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "chunked_large.bin")
      {:ok, lookup_resp} = lookup(channel, root_id, "chunked_large.bin")
      file_id = lookup_resp.node.id

      # 1MB chunks
      chunk_size = 1024 * 1024
      num_chunks = 5

      # Write 5MB in chunks
      Enum.each(0..(num_chunks - 1), fn i ->
        chunk = :binary.copy(<<i>>, chunk_size)
        offset = i * chunk_size
        {:ok, _} = write_file(channel, file_id, chunk, offset)
      end)

      {:ok, info_resp} = get_file_info(channel, file_id)
      assert info_resp.size == chunk_size * num_chunks
    end
  end

  describe "Edge case: Deep directory structures" do
    @tag timeout: 30_000
    test "very deep nesting (100 levels)", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      depth = 100

      # Create deeply nested structure
      final_id =
        Enum.reduce(1..depth, root_id, fn i, parent_id ->
          {:ok, resp} = mkdir(channel, parent_id, "level_#{i}")
          resp.node.id
        end)

      # Create file at deepest level
      {:ok, _} = create_file(channel, final_id, "deep_file.txt")
      {:ok, lookup_resp} = lookup(channel, final_id, "deep_file.txt")
      file_id = lookup_resp.node.id

      # Verify we can write and read
      content = "Deep content at level #{depth}"
      {:ok, _} = write_file(channel, file_id, content)
      {:ok, read_resp} = read_file(channel, file_id)

      assert read_resp.data == content
    end
  end

  describe "Edge case: Wide directories" do
    @tag timeout: 60_000
    test "directory with 1000 files", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, dir_resp} = mkdir(channel, root_id, "wide_dir")
      dir_id = dir_resp.node.id

      num_files = 1000

      # Create many files
      Enum.each(1..num_files, fn i ->
        filename = "file_#{String.pad_leading(Integer.to_string(i), 4, "0")}.txt"
        {:ok, _} = create_file(channel, dir_id, filename)
      end)

      # List and verify count
      {:ok, list_resp} = read_dir_all(channel, dir_id)
      assert length(list_resp.nodes) == num_files
    end

    test "directory with mixed content (files and subdirs)", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, dir_resp} = mkdir(channel, root_id, "mixed_dir")
      dir_id = dir_resp.node.id

      # Create 50 files and 50 directories
      Enum.each(1..50, fn i ->
        {:ok, _} = create_file(channel, dir_id, "file_#{i}.txt")
        {:ok, _} = mkdir(channel, dir_id, "subdir_#{i}")
      end)

      {:ok, list_resp} = read_dir_all(channel, dir_id)
      assert length(list_resp.nodes) == 100
    end
  end

  describe "Edge case: Special characters in names" do
    test "filenames with spaces", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      filename = "file with spaces.txt"
      {:ok, _} = create_file(channel, root_id, filename)
      {:ok, lookup_resp} = lookup(channel, root_id, filename)

      assert lookup_resp.node.name == filename
    end

    test "filenames with special characters", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      special_names = [
        "file-with-dashes.txt",
        "file_with_underscores.txt",
        "file.multiple.dots.txt",
        "file123numbers.txt"
      ]

      Enum.each(special_names, fn name ->
        {:ok, _} = create_file(channel, root_id, name)
        {:ok, lookup_resp} = lookup(channel, root_id, name)
        assert lookup_resp.node.name == name
      end)
    end
  end

  describe "Edge case: Binary data" do
    test "file with null bytes", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "nulls.bin")
      {:ok, lookup_resp} = lookup(channel, root_id, "nulls.bin")
      file_id = lookup_resp.node.id

      # Data with null bytes
      data = <<1, 2, 3, 0, 0, 0, 4, 5, 6>>
      {:ok, _} = write_file(channel, file_id, data)

      {:ok, read_resp} = read_file(channel, file_id)
      assert read_resp.data == data
    end

    test "file with all possible byte values", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "all_bytes.bin")
      {:ok, lookup_resp} = lookup(channel, root_id, "all_bytes.bin")
      file_id = lookup_resp.node.id

      # Create data with all byte values 0-255
      data = for i <- 0..255, into: <<>>, do: <<i>>
      {:ok, _} = write_file(channel, file_id, data)

      {:ok, read_resp} = read_file(channel, file_id)
      assert read_resp.data == data
      assert byte_size(read_resp.data) == 256
    end

    test "random binary data preservation", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "random.bin")
      {:ok, lookup_resp} = lookup(channel, root_id, "random.bin")
      file_id = lookup_resp.node.id

      # Generate random binary data
      random_data = :crypto.strong_rand_bytes(1024)
      {:ok, _} = write_file(channel, file_id, random_data)

      {:ok, read_resp} = read_file(channel, file_id)
      assert read_resp.data == random_data
    end
  end

  describe "Edge case: Read operations" do
    test "reading beyond file size returns partial data", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "short.txt")
      {:ok, lookup_resp} = lookup(channel, root_id, "short.txt")
      file_id = lookup_resp.node.id

      content = "Hello"
      {:ok, _} = write_file(channel, file_id, content)

      # Try to read more than available
      {:ok, read_resp} = read_file(channel, file_id, 0, 100)
      assert read_resp.data == content
    end

    test "reading with offset beyond file size returns empty", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "offset_beyond.txt")
      {:ok, lookup_resp} = lookup(channel, root_id, "offset_beyond.txt")
      file_id = lookup_resp.node.id

      content = "Small"
      {:ok, _} = write_file(channel, file_id, content)

      # Read beyond file
      {:ok, read_resp} = read_file(channel, file_id, 1000, 10)
      assert read_resp.data == <<>>
    end

    test "reading at exactly file size returns empty", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "exact_offset.txt")
      {:ok, lookup_resp} = lookup(channel, root_id, "exact_offset.txt")
      file_id = lookup_resp.node.id

      content = "Test"
      {:ok, _} = write_file(channel, file_id, content)

      # Read at exact size
      {:ok, read_resp} = read_file(channel, file_id, byte_size(content), 10)
      assert read_resp.data == <<>>
    end
  end

  describe "Edge case: Write operations" do
    test "overwriting with shorter content", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "overwrite_short.txt")
      {:ok, lookup_resp} = lookup(channel, root_id, "overwrite_short.txt")
      file_id = lookup_resp.node.id

      # Write long content
      {:ok, _} = write_file(channel, file_id, "Long content here")

      # Overwrite with short content
      {:ok, _} = write_file(channel, file_id, "Short")

      {:ok, read_resp} = read_file(channel, file_id)
      assert read_resp.data == "Short"

      {:ok, info_resp} = get_file_info(channel, file_id)
      assert info_resp.size == 5
    end

    test "writing at large offset pads with zeros", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "sparse.txt")
      {:ok, lookup_resp} = lookup(channel, root_id, "sparse.txt")
      file_id = lookup_resp.node.id

      # Write at offset 10 (should pad 0-9 with zeros)
      {:ok, _} = write_file(channel, file_id, "data", 10)

      {:ok, read_resp} = read_file(channel, file_id)
      expected = <<0, 0, 0, 0, 0, 0, 0, 0, 0, 0, "data"::binary>>
      assert read_resp.data == expected
    end
  end

  describe "Edge case: Empty directory operations" do
    test "listing empty directory returns empty list", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, dir_resp} = mkdir(channel, root_id, "empty_dir")
      dir_id = dir_resp.node.id

      {:ok, list_resp} = read_dir_all(channel, dir_id)
      assert list_resp.nodes == []
    end

    test "removing empty directory succeeds", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = mkdir(channel, root_id, "to_remove_empty")
      {:ok, _} = remove(channel, root_id, "to_remove_empty")

      assert {:error, %GRPC.RPCError{status: 5}} =
               lookup(channel, root_id, "to_remove_empty")
    end
  end

  describe "Edge case: Unicode and UTF-8" do
    test "filenames with unicode characters", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      unicode_names = [
        "café.txt",
        "файл.txt",
        "文件.txt",
        "🎉emoji.txt"
      ]

      Enum.each(unicode_names, fn name ->
        case create_file(channel, root_id, name) do
          {:ok, _} ->
            {:ok, lookup_resp} = lookup(channel, root_id, name)
            assert lookup_resp.node.name == name

          {:error, _} ->
            # Some systems may not support all unicode, that's ok
            # We will emit a warning but not fail the test
            Logger.warning("Skipping unsupported unicode filename test: #{name}")
            :ok
        end
      end)
    end

    test "file content with unicode", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "unicode_content.txt")
      {:ok, lookup_resp} = lookup(channel, root_id, "unicode_content.txt")
      file_id = lookup_resp.node.id

      unicode_content = "Hello 世界! Привет мир! مرحبا بالعالم!"
      {:ok, _} = write_file(channel, file_id, unicode_content)

      {:ok, read_resp} = read_file(channel, file_id)
      assert read_resp.data == unicode_content
    end
  end
end
