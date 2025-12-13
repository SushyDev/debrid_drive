# Suppress logs during tests for cleaner output
Logger.configure(level: :emergency)

ExUnit.start()

Ecto.Adapters.SQL.Sandbox.mode(VFS.Repo, :manual)
