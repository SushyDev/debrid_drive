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
    {:ok, test_dir} = VFS.create_directory(root.id, "test_torrents")

    {:ok, test_dir: test_dir, root: root}
  end

  describe "torrents" do
    test "create_torrent/1 creates a torrent with valid attributes", %{test_dir: test_dir} do
      {:ok, node} = VFS.create_directory(test_dir.id, "test_torrent")

      attrs = %{
        rd_id: "TEST123",
        filename: "Test Torrent",
        hash: "abc123def456",
        bytes: 1_000_000,
        status: "downloaded",
        node_id: node.id
      }

      assert {:ok, %Torrent{} = torrent} = Torrents.create_torrent(attrs)
      assert torrent.rd_id == "TEST123"
      assert torrent.filename == "Test Torrent"
      assert torrent.hash == "abc123def456"
      assert torrent.node_id == node.id
    end

    test "create_torrent/1 fails with duplicate rd_id", %{test_dir: test_dir} do
      {:ok, node1} = VFS.create_directory(test_dir.id, "torrent1")
      {:ok, node2} = VFS.create_directory(test_dir.id, "torrent2")

      attrs1 = %{
        rd_id: "DUPLICATE123",
        filename: "First",
        hash: "hash1",
        bytes: 100,
        node_id: node1.id
      }

      attrs2 = %{
        rd_id: "DUPLICATE123",
        filename: "Second",
        hash: "hash2",
        bytes: 200,
        node_id: node2.id
      }

      assert {:ok, _} = Torrents.create_torrent(attrs1)
      assert {:error, changeset} = Torrents.create_torrent(attrs2)
      assert "has already been taken" in errors_on(changeset).rd_id
    end

    test "get_torrent_by_rd_id/1 returns torrent", %{test_dir: test_dir} do
      {:ok, node} = VFS.create_directory(test_dir.id, "test")

      attrs = %{
        rd_id: "FIND_ME",
        filename: "Find Me",
        hash: "hash",
        bytes: 100,
        node_id: node.id
      }

      {:ok, created} = Torrents.create_torrent(attrs)
      assert {:ok, found} = Torrents.get_torrent_by_rd_id("FIND_ME")
      assert found.id == created.id
    end

    test "delete_torrent/1 removes torrent", %{test_dir: test_dir} do
      {:ok, node} = VFS.create_directory(test_dir.id, "delete_me")

      attrs = %{
        rd_id: "DELETE_ME",
        filename: "Delete Me",
        hash: "hash",
        bytes: 100,
        node_id: node.id
      }

      {:ok, torrent} = Torrents.create_torrent(attrs)
      assert {:ok, _} = Torrents.delete_torrent(torrent)
      assert {:error, :not_found} = Torrents.get_torrent_by_rd_id("DELETE_ME")
    end

    test "get_torrents_by_rd_id/0 returns map of torrents", %{test_dir: test_dir} do
      {:ok, node1} = VFS.create_directory(test_dir.id, "t1")
      {:ok, node2} = VFS.create_directory(test_dir.id, "t2")

      {:ok, _} =
        Torrents.create_torrent(%{
          rd_id: "T1",
          filename: "Torrent 1",
          hash: "h1",
          bytes: 100,
          node_id: node1.id
        })

      {:ok, _} =
        Torrents.create_torrent(%{
          rd_id: "T2",
          filename: "Torrent 2",
          hash: "h2",
          bytes: 200,
          node_id: node2.id
        })

      map = Torrents.get_torrents_by_rd_id()
      assert map_size(map) == 2
      assert Map.has_key?(map, "T1")
      assert Map.has_key?(map, "T2")
    end
  end

  describe "torrent_files" do
    setup %{test_dir: test_dir} do
      {:ok, torrent_node} = VFS.create_directory(test_dir.id, "torrent")

      {:ok, torrent} =
        Torrents.create_torrent(%{
          rd_id: "TORRENT1",
          filename: "Test Torrent",
          hash: "hash",
          bytes: 1000,
          node_id: torrent_node.id
        })

      {:ok, file_node} = VFS.create_file(torrent_node.id, "test_file.mp4", size: 500)

      {:ok, torrent: torrent, file_node: file_node}
    end

    test "create_torrent_file/1 creates file", %{torrent: torrent, file_node: file_node} do
      attrs = %{
        rd_id: 1,
        path: "/test_file.mp4",
        bytes: 500,
        selected: 1,
        torrent_id: torrent.id,
        node_id: file_node.id
      }

      assert {:ok, %TorrentFile{} = file} = Torrents.create_torrent_file(attrs)
      assert file.rd_id == 1
      assert file.path == "/test_file.mp4"
      assert file.torrent_id == torrent.id
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
          torrent_id: torrent.id,
          node_id: file_node.id
        })

      files = Torrents.list_torrent_files(torrent.id)
      assert length(files) == 1
    end

    test "delete_torrent cascades to files", %{torrent: torrent, file_node: file_node} do
      {:ok, _} =
        Torrents.create_torrent_file(%{
          rd_id: 1,
          path: "/file.mp4",
          bytes: 500,
          selected: 1,
          torrent_id: torrent.id,
          node_id: file_node.id
        })

      assert length(Torrents.list_torrent_files(torrent.id)) == 1
      {:ok, _} = Torrents.delete_torrent(torrent)
      assert length(Torrents.list_torrent_files(torrent.id)) == 0
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
