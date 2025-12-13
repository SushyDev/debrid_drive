defmodule SyncEngine.TorrentFileTest do
  use ExUnit.Case, async: false
  alias VFS.Repo
  alias SyncEngine.Torrents
  alias SyncEngine.Schemas.TorrentFile
  alias VFS

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    {:ok, root} = VFS.get_root()
    {:ok, test_dir} = VFS.create_directory(root.inode_id, "test")
    {:ok, torrent_node} = VFS.create_directory(test_dir.inode_id, "torrent")

    {:ok, torrent} =
      Torrents.create_torrent(%{
        rd_id: "TEST",
        filename: "Test",
        hash: "hash",
        bytes: 1000,
        inode_id: torrent_node.inode_id
      })

    {:ok, file_node} = VFS.create_file(torrent_node.inode_id, "file.mp4", size: 500)

    {:ok, torrent: torrent, file_node: file_node}
  end

  describe "link caching" do
    test "link_valid?/1 returns false for nil link" do
      file = %TorrentFile{download_link: nil}
      refute TorrentFile.link_valid?(file)
    end

    test "link_valid?/1 returns true for link without expiration" do
      file = %TorrentFile{download_link: "https://example.com", link_expires_at: nil}
      assert TorrentFile.link_valid?(file)
    end

    test "link_valid?/1 returns false for expired link" do
      expired = DateTime.add(DateTime.utc_now(), -3600, :second)

      file = %TorrentFile{
        download_link: "https://example.com",
        link_expires_at: expired
      }

      refute TorrentFile.link_valid?(file)
    end

    test "link_valid?/1 returns true for non-expired link" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      file = %TorrentFile{
        download_link: "https://example.com",
        link_expires_at: future
      }

      assert TorrentFile.link_valid?(file)
    end

    test "cache_link_changeset/3 sets link and expiration", %{
      torrent: torrent,
      file_node: file_node
    } do
      {:ok, file} =
        Torrents.create_torrent_file(%{
          rd_id: 1,
          path: "/file.mp4",
          bytes: 500,
          selected: 1,
          torrent_id: torrent.id,
          inode_id: file_node.inode_id
        })

      link = "https://download.example.com/file.mp4"
      changeset = TorrentFile.cache_link_changeset(file, link, 7200)

      assert changeset.changes.download_link == link
      assert changeset.changes.link_fetched_at != nil
      assert changeset.changes.link_expires_at != nil

      # Verify expiration is approximately 2 hours in the future
      expires_at = changeset.changes.link_expires_at
      now = DateTime.utc_now()
      diff = DateTime.diff(expires_at, now, :second)
      assert diff >= 7190 and diff <= 7210
    end

    test "cached link persists in database", %{torrent: torrent, file_node: file_node} do
      {:ok, file} =
        Torrents.create_torrent_file(%{
          rd_id: 1,
          path: "/file.mp4",
          bytes: 500,
          selected: 1,
          torrent_id: torrent.id,
          inode_id: file_node.inode_id
        })

      link = "https://download.example.com/cached.mp4"
      changeset = TorrentFile.cache_link_changeset(file, link)

      {:ok, updated} = Repo.update(changeset)
      assert updated.download_link == link
      assert TorrentFile.link_valid?(updated)

      # Reload from database
      reloaded = Repo.get!(TorrentFile, file.id)
      assert reloaded.download_link == link
      assert TorrentFile.link_valid?(reloaded)
    end
  end
end
