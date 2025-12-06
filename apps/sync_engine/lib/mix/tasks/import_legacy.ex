defmodule Mix.Tasks.ImportLegacy do
  @moduledoc """
  Import data from legacy SQLite database files into the new Elixir-based database.

  ## Usage

  In IEx:
      iex> SyncEngine.Import.run("path/to/media.db", "path/to/filesystem.db")

  Or via Mix task:
      mix import_legacy path/to/media.db path/to/filesystem.db
  """
  use Mix.Task
  require Logger

  @shortdoc "Import legacy database files"
  def run([media_db_path, filesystem_db_path]) do
    Mix.Task.run("app.start")

    case SyncEngine.Import.run(media_db_path, filesystem_db_path) do
      {:ok, stats} ->
        Mix.shell().info("Import completed successfully!")
        Mix.shell().info("Statistics:")

        Enum.each(stats, fn {key, value} ->
          Mix.shell().info("  #{key}: #{value}")
        end)

      {:error, reason} ->
        Mix.shell().error("Import failed: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end

  def run(_) do
    Mix.shell().error("Usage: mix import_legacy <media.db> <filesystem.db>")
    exit({:shutdown, 1})
  end
end
