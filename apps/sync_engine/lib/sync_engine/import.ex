defmodule SyncEngine.Import do
  @moduledoc """
  Imports data from legacy Go-based SQLite databases into the new Elixir database.

  This module handles the migration of:
  - VFS nodes from filesystem.db
  - Torrents from media.db
  - Torrent files from media.db
  - Rejected torrents from media.db

  ## Schema Mapping

  ### Old filesystem.db -> New nodes table
  - nodes.id -> nodes.id (but we'll use new IDs)
  - nodes.name -> nodes.name
  - nodes.parent_id -> nodes.parent_id
  - nodes.mode -> nodes.mode
  - nodes.mod_time -> nodes.updated_at
  - nodes.create_time -> nodes.inserted_at
  - node_contents.content -> nodes.data
  - Calculate size from content

  ### Old media.db -> New torrents table
  - torrents.torrent_id -> torrents.rd_id
  - torrents.name -> torrents.filename
  - Set hash to empty string (not in old schema)
  - Set bytes to 0 (not in old schema)
  - Link to VFS node by looking up the node

  ### Old media.db -> New torrent_files table
  - torrent_files.path -> torrent_files.path
  - torrent_files.size -> torrent_files.bytes
  - torrent_files.link -> torrent_files.link
  - torrent_files.file_index -> torrent_files.rd_id
  - Set selected to 1 (assume all files were selected)
  - Link to VFS node by old file_node_id

  ### Old media.db -> New rejected_torrents table
  - rejected_torrents.torrent_id -> rejected_torrents.rd_id
  - rejected_torrents.name -> rejected_torrents.filename
  - Set reason to "legacy import"
  """

  require Logger
  alias VFS.{Repo, Node}
  alias VFS.FileMode
  alias SyncEngine.Schemas.{Torrent, TorrentFile, RejectedTorrent}

  @doc """
  Main entry point for importing legacy databases.

  Returns {:ok, stats} on success or {:error, reason} on failure.
  Stats is a map containing counts of imported records.
  """
  def run(media_db_path, filesystem_db_path) do
    Logger.info("Starting legacy database import")
    Logger.info("Media DB: #{media_db_path}")
    Logger.info("Filesystem DB: #{filesystem_db_path}")

    with {:ok, media_conn} <- connect_db(media_db_path),
         {:ok, fs_conn} <- connect_db(filesystem_db_path) do
      try do
        # Run the import in a transaction
        result =
          Repo.transaction(
            fn ->
              stats = %{
                nodes: 0,
                torrents: 0,
                torrent_files: 0,
                rejected_torrents: 0
              }

              # Import in order of dependencies
              Logger.info("Importing VFS nodes...")
              {:ok, nodes_map, nodes_count} = import_vfs_nodes(fs_conn)
              stats = %{stats | nodes: nodes_count}

              Logger.info("Importing torrents...")
              {:ok, torrents_map, torrents_count} = import_torrents(media_conn, nodes_map)
              stats = %{stats | torrents: torrents_count}

              Logger.info("Importing torrent files...")
              {:ok, files_count} = import_torrent_files(media_conn, torrents_map, nodes_map)
              stats = %{stats | torrent_files: files_count}

              Logger.info("Importing rejected torrents...")
              {:ok, rejected_count} = import_rejected_torrents(media_conn)
              stats = %{stats | rejected_torrents: rejected_count}

              stats
            end,
            timeout: :infinity
          )

        case result do
          {:ok, stats} ->
            Logger.info("Import completed successfully!")
            {:ok, stats}

          {:error, reason} ->
            Logger.error("Import failed: #{inspect(reason)}")
            {:error, reason}
        end
      after
        disconnect_db(media_conn)
        disconnect_db(fs_conn)
      end
    else
      {:error, reason} ->
        Logger.error("Failed to connect to databases: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Connects to a SQLite database
  defp connect_db(path) do
    case Exqlite.Sqlite3.open(path) do
      {:ok, conn} ->
        Logger.debug("Connected to #{path}")
        {:ok, conn}

      {:error, reason} ->
        Logger.error("Failed to open #{path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Disconnects from a SQLite database
  defp disconnect_db(conn) do
    Exqlite.Sqlite3.close(conn)
  end

  # Imports VFS nodes from filesystem.db
  # Returns {:ok, old_id_to_new_node_map, count}
  defp import_vfs_nodes(fs_conn) do
    # Query all nodes ordered by parent_id (so parents come before children)
    query = """
    SELECT id, name, parent_id, mode, create_time, mod_time
    FROM nodes
    ORDER BY 
      CASE WHEN parent_id IS NULL THEN 0 ELSE 1 END,
      parent_id,
      id
    """

    {:ok, statement} = Exqlite.Sqlite3.prepare(fs_conn, query)

    nodes =
      stream_results(fs_conn, statement)
      |> Enum.to_list()

    Exqlite.Sqlite3.release(fs_conn, statement)

    # Also get node contents
    contents_query = "SELECT node_id, content FROM node_contents"
    {:ok, contents_statement} = Exqlite.Sqlite3.prepare(fs_conn, contents_query)

    contents_map =
      stream_results(fs_conn, contents_statement)
      |> Enum.map(fn [node_id, content] -> {node_id, content} end)
      |> Map.new()

    Exqlite.Sqlite3.release(fs_conn, contents_statement)

    # Build a map from old ID to new node
    {nodes_map, count} =
      Enum.reduce(nodes, {%{}, 0}, fn [old_id, name, old_parent_id, mode, create_time, mod_time],
                                      {acc_map, acc_count} ->
        # Look up new parent ID
        new_parent_id =
          case old_parent_id do
            nil -> nil
            parent -> Map.get(acc_map, parent) |> then(& &1.id)
          end

        # Get content if exists
        content = Map.get(contents_map, old_id)
        size = if content, do: byte_size(content), else: 0

        # Parse timestamps
        inserted_at = parse_timestamp(create_time)
        updated_at = parse_timestamp(mod_time)

        # Create node
        attrs = %{
          name: name,
          parent_id: new_parent_id,
          mode: mode,
          data: content,
          size: size,
          # Try to infer content type
          content_type: infer_content_type(name, mode)
        }

        changeset = Node.changeset(%Node{}, attrs)

        node =
          changeset
          |> Repo.insert!(
            # Set timestamps manually
            on_conflict: :nothing,
            conflict_target: [:parent_id, :name]
          )
          |> update_timestamps(inserted_at, updated_at)

        {Map.put(acc_map, old_id, node), acc_count + 1}
      end)

    Logger.info("Imported #{count} VFS nodes")
    {:ok, nodes_map, count}
  end

  # Imports torrents from media.db
  # Returns {:ok, old_id_to_new_torrent_map, count}
  defp import_torrents(media_conn, nodes_map) do
    query = "SELECT id, torrent_id, name FROM torrents"
    {:ok, statement} = Exqlite.Sqlite3.prepare(media_conn, query)

    torrents =
      stream_results(media_conn, statement)
      |> Enum.to_list()

    Exqlite.Sqlite3.release(media_conn, statement)

    # For each torrent, we need to find its VFS node
    # The old system stored torrents in directories, we need to find them
    {torrents_map, count} =
      Enum.reduce(torrents, {%{}, 0}, fn [old_id, rd_id, filename], {acc_map, acc_count} ->
        # Try to find the node for this torrent by name
        # In the old system, torrents were directories
        node = find_torrent_node(nodes_map, filename)

        case node do
          nil ->
            Logger.warning("Could not find VFS node for torrent: #{filename} (#{rd_id})")
            {acc_map, acc_count}

          node ->
            # Create torrent
            attrs = %{
              rd_id: rd_id,
              filename: filename,
              # We don't have these in the old schema
              hash: "",
              bytes: 0,
              node_id: node.id
            }

            torrent =
              %Torrent{}
              |> Torrent.changeset(attrs)
              |> Repo.insert!(on_conflict: :nothing, conflict_target: :rd_id)

            {Map.put(acc_map, old_id, torrent), acc_count + 1}
        end
      end)

    Logger.info("Imported #{count} torrents")
    {:ok, torrents_map, count}
  end

  # Imports torrent files from media.db
  # Returns {:ok, count}
  defp import_torrent_files(media_conn, torrents_map, nodes_map) do
    query = """
    SELECT id, torrent_id, path, size, link, file_index, file_node_id
    FROM torrent_files
    """

    {:ok, statement} = Exqlite.Sqlite3.prepare(media_conn, query)

    count =
      stream_results(media_conn, statement)
      |> Enum.reduce(0, fn [_old_id, old_torrent_id, path, size, link, file_index, file_node_id],
                           acc_count ->
        # Look up new torrent and node IDs
        torrent = Map.get(torrents_map, old_torrent_id)
        node = Map.get(nodes_map, file_node_id)

        case {torrent, node} do
          {nil, _} ->
            Logger.warning("Torrent not found for file: #{path}")
            acc_count

          {_, nil} ->
            Logger.warning("VFS node not found for file: #{path}")
            acc_count

          {torrent, node} ->
            attrs = %{
              rd_id: file_index,
              path: path,
              bytes: size,
              selected: 1,
              link: link,
              torrent_id: torrent.id,
              node_id: node.id
            }

            %TorrentFile{}
            |> TorrentFile.changeset(attrs)
            |> Repo.insert!(
              on_conflict: :nothing,
              conflict_target: [:torrent_id, :rd_id]
            )

            acc_count + 1
        end
      end)

    Exqlite.Sqlite3.release(media_conn, statement)
    Logger.info("Imported #{count} torrent files")
    {:ok, count}
  end

  # Imports rejected torrents from media.db
  # Returns {:ok, count}
  defp import_rejected_torrents(media_conn) do
    query = "SELECT torrent_id, name FROM rejected_torrents"
    {:ok, statement} = Exqlite.Sqlite3.prepare(media_conn, query)

    count =
      stream_results(media_conn, statement)
      |> Enum.reduce(0, fn [rd_id, filename], acc_count ->
        attrs = %{
          rd_id: rd_id,
          filename: filename,
          reason: "legacy_import",
          last_attempted_at: DateTime.utc_now() |> DateTime.truncate(:second)
        }

        %RejectedTorrent{}
        |> RejectedTorrent.changeset(attrs)
        |> Repo.insert!(on_conflict: :nothing, conflict_target: :rd_id)

        acc_count + 1
      end)

    Exqlite.Sqlite3.release(media_conn, statement)
    Logger.info("Imported #{count} rejected torrents")
    {:ok, count}
  end

  # Helper to stream results from a prepared statement
  defp stream_results(conn, statement) do
    Stream.resource(
      fn -> {conn, statement} end,
      fn {conn, stmt} ->
        case Exqlite.Sqlite3.step(conn, stmt) do
          {:row, row} -> {[row], {conn, stmt}}
          :done -> {:halt, {conn, stmt}}
          {:error, reason} -> raise "Query failed: #{inspect(reason)}"
        end
      end,
      fn _state -> :ok end
    )
  end

  # Finds a torrent node by filename in the nodes map
  defp find_torrent_node(nodes_map, filename) do
    nodes_map
    |> Map.values()
    |> Enum.find(fn node ->
      node.name == filename && FileMode.dir?(node.mode)
    end)
  end

  # Infers content type based on filename and mode
  defp infer_content_type(_name, mode) do
    if FileMode.dir?(mode) do
      "inode/directory"
    else
      "application/octet-stream"
    end
  end

  # Parses a timestamp string into a DateTime
  defp parse_timestamp(nil), do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp parse_timestamp(timestamp_str) when is_binary(timestamp_str) do
    # Try to parse various timestamp formats
    case DateTime.from_iso8601(timestamp_str) do
      {:ok, dt, _offset} ->
        DateTime.truncate(dt, :second)

      {:error, _} ->
        # Try parsing as Unix timestamp
        case Integer.parse(timestamp_str) do
          {unix_time, _} ->
            DateTime.from_unix!(unix_time) |> DateTime.truncate(:second)

          :error ->
            Logger.warning("Could not parse timestamp: #{timestamp_str}")
            DateTime.utc_now() |> DateTime.truncate(:second)
        end
    end
  end

  defp parse_timestamp(unix_time) when is_integer(unix_time) do
    DateTime.from_unix!(unix_time) |> DateTime.truncate(:second)
  end

  # Updates timestamps on a node using raw SQL to bypass Ecto's automatic timestamp handling
  defp update_timestamps(node, inserted_at, updated_at) do
    query = """
    UPDATE nodes
    SET inserted_at = ?, updated_at = ?
    WHERE id = ?
    """

    Repo.query!(query, [inserted_at, updated_at, node.id])
    # Reload the node to get updated timestamps
    Repo.get!(Node, node.id)
  end
end
