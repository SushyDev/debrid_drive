defmodule GrpcServer.E2E.ConcurrentStressTest do
  @moduledoc """
  Stress tests for the gRPC server with concurrent operations.
  Tests the server's ability to handle multiple simultaneous requests.
  """
  use ExUnit.Case, async: false

  import GrpcServer.Test.GrpcClientHelper

  # Note: async: false because we want to control concurrency within tests
  # and avoid interference between stress tests

  setup do
    # Start sandbox for this test
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(VFS.Repo)

    # Allow concurrent database access from spawned processes
    Ecto.Adapters.SQL.Sandbox.mode(VFS.Repo, {:shared, self()})

    # Connect to gRPC server
    channel = connect()

    on_exit(fn ->
      disconnect(channel)
    end)

    {:ok, channel: channel}
  end

  describe "Concurrent reads" do
    test "multiple clients can read the same file simultaneously", %{channel: _channel} do
      # Create separate connections for each client
      channels = Enum.map(1..10, fn _ -> connect() end)

      try do
        # Set up: create a file with content
        setup_channel = hd(channels)
        {:ok, root_resp} = get_root(setup_channel)
        root_id = root_resp.root.id

        {:ok, _} = create_file(setup_channel, root_id, "concurrent_read.txt")
        {:ok, lookup_resp} = lookup(setup_channel, root_id, "concurrent_read.txt")
        file_id = lookup_resp.node.id

        content = "Shared content for concurrent reads"
        {:ok, _} = write_file(setup_channel, file_id, content)

        # Spawn concurrent readers
        tasks =
          Enum.map(channels, fn ch ->
            Task.async(fn ->
              {:ok, read_resp} = read_file(ch, file_id)
              read_resp.data
            end)
          end)

        # Collect results
        results = Task.await_many(tasks, 5000)

        # Verify all reads got the same content
        assert Enum.all?(results, &(&1 == content))
      after
        Enum.each(channels, &disconnect/1)
      end
    end

    test "concurrent reads of different files", %{channel: _channel} do
      channels = Enum.map(1..20, fn _ -> connect() end)

      try do
        setup_channel = hd(channels)
        {:ok, root_resp} = get_root(setup_channel)
        root_id = root_resp.root.id

        # Create multiple files
        file_ids =
          Enum.map(1..20, fn i ->
            filename = "file_#{i}.txt"
            content = "Content of file #{i}"
            {:ok, _} = create_file(setup_channel, root_id, filename)
            {:ok, lookup_resp} = lookup(setup_channel, root_id, filename)
            {:ok, _} = write_file(setup_channel, lookup_resp.node.id, content)
            {lookup_resp.node.id, content}
          end)

        # Each task reads a different file
        tasks =
          Enum.zip(channels, file_ids)
          |> Enum.map(fn {ch, {file_id, expected_content}} ->
            Task.async(fn ->
              {:ok, read_resp} = read_file(ch, file_id)
              {read_resp.data, expected_content}
            end)
          end)

        results = Task.await_many(tasks, 5000)

        # Verify each read got the correct content
        assert Enum.all?(results, fn {actual, expected} -> actual == expected end)
      after
        Enum.each(channels, &disconnect/1)
      end
    end
  end

  describe "Concurrent writes" do
    test "concurrent writes to different files don't interfere", %{channel: _channel} do
      channels = Enum.map(1..10, fn _ -> connect() end)

      try do
        setup_channel = hd(channels)
        {:ok, root_resp} = get_root(setup_channel)
        root_id = root_resp.root.id

        # Create files for each writer
        file_ids =
          Enum.map(1..10, fn i ->
            filename = "write_file_#{i}.txt"
            {:ok, _} = create_file(setup_channel, root_id, filename)
            {:ok, lookup_resp} = lookup(setup_channel, root_id, filename)
            lookup_resp.node.id
          end)

        # Concurrent writes
        tasks =
          Enum.zip(channels, file_ids)
          |> Enum.with_index(1)
          |> Enum.map(fn {{ch, file_id}, index} ->
            Task.async(fn ->
              content = "Data from writer #{index}"
              {:ok, _} = write_file(ch, file_id, content)
              {file_id, content}
            end)
          end)

        written_data = Task.await_many(tasks, 5000)

        # Verify each file has correct content
        Enum.each(written_data, fn {file_id, expected_content} ->
          {:ok, read_resp} = read_file(setup_channel, file_id)
          assert read_resp.data == expected_content
        end)
      after
        Enum.each(channels, &disconnect/1)
      end
    end

    test "sequential writes to same file are consistent", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "sequential.txt")
      {:ok, lookup_resp} = lookup(channel, root_id, "sequential.txt")
      file_id = lookup_resp.node.id

      # Write multiple times
      Enum.each(1..50, fn i ->
        content = "Write number #{i}"
        {:ok, _} = write_file(channel, file_id, content)
      end)

      # Final read should have last write
      {:ok, read_resp} = read_file(channel, file_id)
      assert read_resp.data == "Write number 50"
    end
  end

  describe "Concurrent directory operations" do
    test "concurrent directory creation", %{channel: _channel} do
      channels = Enum.map(1..15, fn _ -> connect() end)

      try do
        setup_channel = hd(channels)
        {:ok, root_resp} = get_root(setup_channel)
        root_id = root_resp.root.id

        # Spawn concurrent directory creators
        tasks =
          channels
          |> Enum.with_index(1)
          |> Enum.map(fn {ch, index} ->
            Task.async(fn ->
              dirname = "dir_#{index}"
              {:ok, resp} = mkdir(ch, root_id, dirname)
              resp.node.name
            end)
          end)

        _created_names = Task.await_many(tasks, 5000)

        # Verify all directories were created
        {:ok, list_resp} = read_dir_all(setup_channel, root_id)
        actual_names = Enum.map(list_resp.nodes, & &1.name) |> Enum.sort()
        expected_names = Enum.map(1..15, &"dir_#{&1}") |> Enum.sort()

        assert actual_names == expected_names
      after
        Enum.each(channels, &disconnect/1)
      end
    end

    test "concurrent file creation in same directory", %{channel: _channel} do
      channels = Enum.map(1..20, fn _ -> connect() end)

      try do
        setup_channel = hd(channels)
        {:ok, root_resp} = get_root(setup_channel)
        root_id = root_resp.root.id

        # Create directory
        {:ok, dir_resp} = mkdir(setup_channel, root_id, "shared_dir")
        dir_id = dir_resp.node.id

        # Concurrent file creation in the same directory
        tasks =
          channels
          |> Enum.with_index(1)
          |> Enum.map(fn {ch, index} ->
            Task.async(fn ->
              filename = "file_#{index}.txt"
              {:ok, _} = create_file(ch, dir_id, filename)
              filename
            end)
          end)

        Task.await_many(tasks, 5000)

        # Verify all files exist
        {:ok, list_resp} = read_dir_all(setup_channel, dir_id)
        assert length(list_resp.nodes) == 20
      after
        Enum.each(channels, &disconnect/1)
      end
    end
  end

  describe "Mixed concurrent operations" do
    test "concurrent reads, writes, and creates", %{channel: _channel} do
      channels = Enum.map(1..30, fn _ -> connect() end)

      try do
        setup_channel = hd(channels)
        {:ok, root_resp} = get_root(setup_channel)
        root_id = root_resp.root.id

        # Pre-create a file for reading
        {:ok, _} = create_file(setup_channel, root_id, "read_target.txt")
        {:ok, lookup_resp} = lookup(setup_channel, root_id, "read_target.txt")
        read_file_id = lookup_resp.node.id
        {:ok, _} = write_file(setup_channel, read_file_id, "Read this!")

        # Divide channels into readers, writers, and creators
        {read_channels, rest} = Enum.split(channels, 10)
        {write_channels, create_channels} = Enum.split(rest, 10)

        # Spawn mixed operations
        read_tasks =
          Enum.map(read_channels, fn ch ->
            Task.async(fn ->
              {:ok, resp} = read_file(ch, read_file_id)
              {:read, resp.data}
            end)
          end)

        write_tasks =
          write_channels
          |> Enum.with_index(1)
          |> Enum.map(fn {ch, i} ->
            Task.async(fn ->
              filename = "write_target_#{i}.txt"
              {:ok, _} = create_file(ch, root_id, filename)
              {:ok, lookup} = lookup(ch, root_id, filename)
              content = "Write #{i}"
              {:ok, _} = write_file(ch, lookup.node.id, content)
              {:write, i}
            end)
          end)

        create_tasks =
          create_channels
          |> Enum.with_index(1)
          |> Enum.map(fn {ch, i} ->
            Task.async(fn ->
              {:ok, _} = mkdir(ch, root_id, "created_dir_#{i}")
              {:create, i}
            end)
          end)

        all_tasks = read_tasks ++ write_tasks ++ create_tasks
        results = Task.await_many(all_tasks, 10000)

        # Verify we got all results
        assert length(results) == 30

        # Verify reads succeeded
        read_results = Enum.filter(results, fn {type, _} -> type == :read end)
        assert length(read_results) == 10
        assert Enum.all?(read_results, fn {:read, data} -> data == "Read this!" end)
      after
        Enum.each(channels, &disconnect/1)
      end
    end
  end

  describe "Stress: High volume operations" do
    @tag timeout: 60_000
    test "create and read many small files rapidly", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create directory for test
      {:ok, dir_resp} = mkdir(channel, root_id, "stress_test")
      dir_id = dir_resp.node.id

      num_files = 100

      # Rapidly create files
      file_ids =
        Enum.map(1..num_files, fn i ->
          filename = "stress_#{i}.txt"
          {:ok, _} = create_file(channel, dir_id, filename)
          {:ok, lookup_resp} = lookup(channel, dir_id, filename)
          content = "Stress test content #{i}"
          {:ok, _} = write_file(channel, lookup_resp.node.id, content)
          {lookup_resp.node.id, content}
        end)

      # Read all files back
      Enum.each(file_ids, fn {file_id, expected_content} ->
        {:ok, read_resp} = read_file(channel, file_id)
        assert read_resp.data == expected_content
      end)

      # Verify directory listing
      {:ok, list_resp} = read_dir_all(channel, dir_id)
      assert length(list_resp.nodes) == num_files
    end

    @tag timeout: 60_000
    test "deep directory nesting", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      depth = 50

      # Create deep nested directories
      final_id =
        Enum.reduce(1..depth, root_id, fn i, parent_id ->
          {:ok, resp} = mkdir(channel, parent_id, "level_#{i}")
          resp.node.id
        end)

      # Create a file in the deepest directory
      {:ok, _} = create_file(channel, final_id, "deep_file.txt")
      {:ok, lookup_resp} = lookup(channel, final_id, "deep_file.txt")

      # Write and read from deep file
      content = "Deep nested content"
      {:ok, _} = write_file(channel, lookup_resp.node.id, content)
      {:ok, read_resp} = read_file(channel, lookup_resp.node.id)

      assert read_resp.data == content
    end

    @tag timeout: 60_000
    test "large file operations", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, _} = create_file(channel, root_id, "large_file.bin")
      {:ok, lookup_resp} = lookup(channel, root_id, "large_file.bin")
      file_id = lookup_resp.node.id

      # Write 1MB of data
      # 64KB chunks
      chunk_size = 64 * 1024
      # Total 1MB
      num_chunks = 16

      Enum.each(0..(num_chunks - 1), fn i ->
        # Generate unique data for each chunk
        chunk_data = :binary.copy(<<i>>, chunk_size)
        offset = i * chunk_size
        {:ok, _} = write_file(channel, file_id, chunk_data, offset)
      end)

      # Verify file size
      {:ok, info_resp} = get_file_info(channel, file_id)
      assert info_resp.size == chunk_size * num_chunks

      # Read back and verify
      {:ok, read_resp} = read_file(channel, file_id)
      assert byte_size(read_resp.data) == chunk_size * num_chunks
    end
  end

  describe "Stress: Rapid create/delete cycles" do
    test "create and delete files rapidly", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      # Create directory for test
      {:ok, dir_resp} = mkdir(channel, root_id, "churn_test")
      dir_id = dir_resp.node.id

      # Rapid create/delete cycles
      Enum.each(1..50, fn i ->
        filename = "churn_#{i}.txt"
        {:ok, _} = create_file(channel, dir_id, filename)
        {:ok, _} = remove(channel, dir_id, filename)
      end)

      # Directory should be empty
      {:ok, list_resp} = read_dir_all(channel, dir_id)
      assert list_resp.nodes == []
    end

    test "create, rename, and delete pattern", %{channel: channel} do
      {:ok, root_resp} = get_root(channel)
      root_id = root_resp.root.id

      {:ok, dir_resp} = mkdir(channel, root_id, "rename_test")
      dir_id = dir_resp.node.id

      Enum.each(1..30, fn i ->
        # Create
        filename = "temp_#{i}.txt"
        {:ok, _} = create_file(channel, dir_id, filename)

        # Rename
        new_name = "renamed_#{i}.txt"
        {:ok, _} = rename(channel, dir_id, filename, dir_id, new_name)

        # Delete
        {:ok, _} = remove(channel, dir_id, new_name)
      end)

      # Directory should be empty
      {:ok, list_resp} = read_dir_all(channel, dir_id)
      assert list_resp.nodes == []
    end
  end
end
