defmodule DbInfo do
  @moduledoc """
  IEx helper module for inspecting database state.

  ## Usage in IEx

      iex> DbInfo.overview()
      iex> DbInfo.torrents()
      iex> DbInfo.stats()
      iex> DbInfo.queue()
  """

  import Ecto.Query
  alias VFS.Repo
  alias SyncEngine.Schemas.{Torrent, TorrentFile, RejectedTorrent}
  alias VFS.{Node, FileMode}

  @doc """
  Shows a complete database overview with all relevant stats.

  ## Example

      iex> DbInfo.overview()
  """
  def overview do
    IO.puts(
      "\n" <>
        IO.ANSI.cyan() <>
        "═══════════════════════════════════════════════════════" <> IO.ANSI.reset()
    )

    IO.puts(IO.ANSI.cyan() <> "  DATABASE OVERVIEW" <> IO.ANSI.reset())

    IO.puts(
      IO.ANSI.cyan() <>
        "═══════════════════════════════════════════════════════" <> IO.ANSI.reset()
    )

    # VFS Stats
    total_nodes = Repo.aggregate(Node, :count, :id)

    directories =
      Repo.aggregate(from(n in Node, where: fragment("(? & 0x4000) != 0", n.mode)), :count, :id)

    files =
      Repo.aggregate(from(n in Node, where: fragment("(? & 0x8000) != 0", n.mode)), :count, :id)

    hardlinks =
      Repo.aggregate(from(n in Node, where: n.content_type == "inode/hardlink"), :count, :id)

    IO.puts("\n" <> IO.ANSI.yellow() <> "📁 VFS (Virtual File System)" <> IO.ANSI.reset())
    IO.puts("  Total Nodes:    #{format_number(total_nodes)}")
    IO.puts("  ├─ Directories: #{format_number(directories)}")
    IO.puts("  ├─ Files:       #{format_number(files)}")
    IO.puts("  └─ Hard Links:  #{format_number(hardlinks)}")

    # Torrent Stats
    total_torrents = Repo.aggregate(Torrent, :count, :id)

    active_torrents =
      Repo.aggregate(
        from(t in Torrent, where: is_nil(t.deletion_status) or t.deletion_status == "active"),
        :count,
        :id
      )

    pending_deletion =
      Repo.aggregate(
        from(t in Torrent, where: t.deletion_status == "pending_deletion"),
        :count,
        :id
      )

    failed_deletion =
      Repo.aggregate(from(t in Torrent, where: t.deletion_status == "failed"), :count, :id)

    total_files = Repo.aggregate(TorrentFile, :count, :id)
    total_size = Repo.aggregate(TorrentFile, :sum, :bytes) || 0

    rejected = Repo.aggregate(RejectedTorrent, :count, :id)

    IO.puts("\n" <> IO.ANSI.yellow() <> "🔥 Torrents" <> IO.ANSI.reset())
    IO.puts("  Total:          #{format_number(total_torrents)}")
    IO.puts("  ├─ Active:      #{format_number(active_torrents)}")
    IO.puts("  ├─ Pending:     #{format_number(pending_deletion)}")
    IO.puts("  └─ Failed:      #{format_number(failed_deletion)}")

    IO.puts("\n" <> IO.ANSI.yellow() <> "📄 Torrent Files" <> IO.ANSI.reset())
    IO.puts("  Total Files:    #{format_number(total_files)}")
    IO.puts("  Total Size:     #{format_bytes(total_size)}")

    if rejected > 0 do
      IO.puts("\n" <> IO.ANSI.yellow() <> "⚠️  Rejected Torrents" <> IO.ANSI.reset())
      IO.puts("  Count:          #{format_number(rejected)}")
    end

    # Job Queue Stats
    queue_stats = SyncEngine.JobQueue.status()

    IO.puts("\n" <> IO.ANSI.yellow() <> "⚙️  Job Queue" <> IO.ANSI.reset())
    IO.puts("  Queue Length:   #{queue_stats.queue_length}")
    IO.puts("  Processing:     #{if queue_stats.processing, do: "Yes", else: "Idle"}")
    IO.puts("  Stats:")
    IO.puts("    ├─ Processed: #{queue_stats.stats.processed}")
    IO.puts("    ├─ Succeeded: #{queue_stats.stats.succeeded}")
    IO.puts("    └─ Failed:    #{queue_stats.stats.failed}")

    IO.puts(
      "\n" <>
        IO.ANSI.cyan() <>
        "═══════════════════════════════════════════════════════" <> IO.ANSI.reset() <> "\n"
    )

    :ok
  end

  @doc """
  Shows detailed torrent information.

  ## Example

      iex> DbInfo.torrents()
      iex> DbInfo.torrents(limit: 5)
  """
  def torrents(opts \\ []) do
    limit = Keyword.get(opts, :limit, 10)

    torrents =
      Torrent
      |> preload(:files)
      |> order_by([t], desc: t.inserted_at)
      |> limit(^limit)
      |> Repo.all()

    IO.puts(
      "\n" <>
        IO.ANSI.cyan() <>
        "═══════════════════════════════════════════════════════" <> IO.ANSI.reset()
    )

    IO.puts(
      IO.ANSI.cyan() <>
        "  TORRENTS (showing #{length(torrents)} of #{Repo.aggregate(Torrent, :count, :id)})" <>
        IO.ANSI.reset()
    )

    IO.puts(
      IO.ANSI.cyan() <>
        "═══════════════════════════════════════════════════════" <> IO.ANSI.reset() <> "\n"
    )

    Enum.each(torrents, fn torrent ->
      status_color =
        case torrent.deletion_status do
          nil -> IO.ANSI.green()
          "active" -> IO.ANSI.green()
          "pending_deletion" -> IO.ANSI.yellow()
          "failed" -> IO.ANSI.red()
          _ -> IO.ANSI.white()
        end

      status_text = torrent.deletion_status || "active"
      file_count = length(torrent.files)
      total_size = Enum.reduce(torrent.files, 0, fn f, acc -> acc + f.bytes end)

      IO.puts("#{IO.ANSI.bright()}#{truncate(torrent.filename, 50)}#{IO.ANSI.reset()}")
      IO.puts("  ID:     #{torrent.id} (RD: #{torrent.rd_id})")
      IO.puts("  Status: #{status_color}#{status_text}#{IO.ANSI.reset()}")
      IO.puts("  Files:  #{file_count} files (#{format_bytes(total_size)})")

      if torrent.deletion_error do
        IO.puts(
          "  #{IO.ANSI.red()}Error:  #{truncate(torrent.deletion_error, 60)}#{IO.ANSI.reset()}"
        )
      end

      IO.puts("")
    end)

    :ok
  end

  @doc """
  Shows quick stats summary.

  ## Example

      iex> DbInfo.stats()
  """
  def stats do
    torrent_count = Repo.aggregate(Torrent, :count, :id)
    file_count = Repo.aggregate(TorrentFile, :count, :id)
    node_count = Repo.aggregate(Node, :count, :id)
    total_size = Repo.aggregate(TorrentFile, :sum, :bytes) || 0

    IO.puts("\n📊 Quick Stats:")
    IO.puts("  Torrents:  #{format_number(torrent_count)}")
    IO.puts("  Files:     #{format_number(file_count)}")
    IO.puts("  Nodes:     #{format_number(node_count)}")
    IO.puts("  Size:      #{format_bytes(total_size)}\n")

    :ok
  end

  @doc """
  Shows job queue status.

  ## Example

      iex> DbInfo.queue()
  """
  def queue do
    queue_stats = SyncEngine.JobQueue.status()

    IO.puts("\n⚙️  Job Queue Status:")
    IO.puts("  Queue Length:   #{queue_stats.queue_length}")
    IO.puts("  Processing:     #{if queue_stats.processing, do: "Yes", else: "Idle"}")

    if queue_stats.processing do
      job = queue_stats.processing
      IO.puts("  Current Job:")
      IO.puts("    Type:       #{job.type}")
      IO.puts("    Retry:      #{job.retry_count}/3")
    end

    IO.puts("  Lifetime Stats:")
    IO.puts("    Processed:  #{queue_stats.stats.processed}")
    IO.puts("    Succeeded:  #{queue_stats.stats.succeeded}")
    IO.puts("    Failed:     #{queue_stats.stats.failed}\n")

    :ok
  end

  @doc """
  Shows rejected torrents.

  ## Example

      iex> DbInfo.rejected()
  """
  def rejected do
    rejected =
      RejectedTorrent
      |> order_by([r], desc: r.last_attempted_at)
      |> Repo.all()

    if Enum.empty?(rejected) do
      IO.puts("\n✅ No rejected torrents\n")
    else
      IO.puts(
        "\n" <>
          IO.ANSI.cyan() <>
          "═══════════════════════════════════════════════════════" <> IO.ANSI.reset()
      )

      IO.puts(IO.ANSI.cyan() <> "  REJECTED TORRENTS (#{length(rejected)})" <> IO.ANSI.reset())

      IO.puts(
        IO.ANSI.cyan() <>
          "═══════════════════════════════════════════════════════" <> IO.ANSI.reset() <> "\n"
      )

      Enum.each(rejected, fn r ->
        IO.puts("#{IO.ANSI.red()}#{truncate(r.filename, 50)}#{IO.ANSI.reset()}")
        IO.puts("  RD ID:    #{r.rd_id}")
        IO.puts("  Reason:   #{r.reason}")
        IO.puts("  Attempts: #{r.attempt_count}")
        IO.puts("")
      end)
    end

    :ok
  end

  @doc """
  Shows VFS tree structure.

  ## Example

      iex> DbInfo.tree()
      iex> DbInfo.tree(max_depth: 2)
  """
  def tree(opts \\ []) do
    max_depth = Keyword.get(opts, :max_depth, 3)

    {:ok, root} = VFS.get_root()

    IO.puts("\n📁 VFS Tree (max depth: #{max_depth}):\n")
    print_tree(root, 0, max_depth)
    IO.puts("")

    :ok
  end

  # Private helpers

  defp print_tree(_node, depth, max_depth) when depth >= max_depth do
    :ok
  end

  defp print_tree(node, depth, max_depth) do
    indent = String.duplicate("  ", depth)
    icon = if FileMode.dir?(node.mode), do: "📁", else: "📄"

    size_info =
      if FileMode.dir?(node.mode) do
        ""
      else
        " (#{format_bytes(node.size)})"
      end

    IO.puts("#{indent}#{icon} #{node.name}#{size_info}")

    if FileMode.dir?(node.mode) do
      children = VFS.list_children(node.id)

      Enum.each(children, fn child ->
        print_tree(child, depth + 1, max_depth)
      end)
    end
  end

  defp format_number(num) when num >= 1_000_000 do
    "#{Float.round(num / 1_000_000, 2)}M"
  end

  defp format_number(num) when num >= 1_000 do
    "#{Float.round(num / 1_000, 2)}K"
  end

  defp format_number(num), do: "#{num}"

  defp format_bytes(bytes) when bytes >= 1_099_511_627_776 do
    "#{Float.round(bytes / 1_099_511_627_776, 2)} TB"
  end

  defp format_bytes(bytes) when bytes >= 1_073_741_824 do
    "#{Float.round(bytes / 1_073_741_824, 2)} GB"
  end

  defp format_bytes(bytes) when bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 2)} MB"
  end

  defp format_bytes(bytes) when bytes >= 1_024 do
    "#{Float.round(bytes / 1_024, 2)} KB"
  end

  defp format_bytes(bytes), do: "#{bytes} B"

  defp truncate(string, max_length) do
    if String.length(string) > max_length do
      String.slice(string, 0, max_length - 3) <> "..."
    else
      string
    end
  end
end

# Print welcome message
IO.puts("\n#{IO.ANSI.cyan()}╔════════════════════════════════════════════════════════════╗#{IO.ANSI.reset()}")
IO.puts("#{IO.ANSI.cyan()}║#{IO.ANSI.reset()}  #{IO.ANSI.bright()}Debrid Drive IEx Helper#{IO.ANSI.reset()}                              #{IO.ANSI.cyan()}║#{IO.ANSI.reset()}")
IO.puts("#{IO.ANSI.cyan()}╚════════════════════════════════════════════════════════════╝#{IO.ANSI.reset()}\n")
IO.puts("#{IO.ANSI.yellow()}Available commands:#{IO.ANSI.reset()}")
IO.puts("  #{IO.ANSI.green()}DbInfo.overview()#{IO.ANSI.reset()}   - Complete database overview")
IO.puts("  #{IO.ANSI.green()}DbInfo.stats()#{IO.ANSI.reset()}      - Quick stats summary")
IO.puts("  #{IO.ANSI.green()}DbInfo.torrents()#{IO.ANSI.reset()}   - Show torrent details")
IO.puts("  #{IO.ANSI.green()}DbInfo.queue()#{IO.ANSI.reset()}      - Job queue status")
IO.puts("  #{IO.ANSI.green()}DbInfo.rejected()#{IO.ANSI.reset()}   - Show rejected torrents")
IO.puts("  #{IO.ANSI.green()}DbInfo.tree()#{IO.ANSI.reset()}       - VFS tree structure\n")
