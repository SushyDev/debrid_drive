defmodule Mix.Tasks.Vfs.Reset do
  @moduledoc """
  Resets the VFS database by dropping and recreating all tables.

  This will:
  - Drop the database
  - Create the database
  - Run all migrations

  ## Usage

      mix vfs.reset

  ## Options

      --quiet  - Run without confirmation prompt (use with caution!)

  """
  use Mix.Task

  @shortdoc "Drops, creates, and migrates the VFS database"

  @impl Mix.Task
  def run(args) do
    # Parse options
    {opts, _, _} = OptionParser.parse(args, switches: [quiet: :boolean])
    quiet = Keyword.get(opts, :quiet, false)

    unless quiet do
      Mix.shell().info("""
      WARNING: This will delete ALL data in the VFS database including:
      - All VFS nodes (files and directories)
      - All torrents and torrent files
      - All associated metadata

      This action cannot be undone!
      """)

      if Mix.shell().yes?("Are you sure you want to continue?") do
        perform_reset()
      else
        Mix.shell().info("Reset cancelled.")
      end
    else
      perform_reset()
    end
  end

  defp perform_reset do
    Mix.shell().info("Dropping database...")
    Mix.Task.run("ecto.drop", ["-r", "VFS.Repo"])

    Mix.shell().info("Creating database...")
    Mix.Task.run("ecto.create", ["-r", "VFS.Repo"])

    Mix.shell().info("Running migrations...")
    Mix.Task.run("ecto.migrate", ["-r", "VFS.Repo"])

    Mix.shell().info("Database reset complete!")
  end
end
