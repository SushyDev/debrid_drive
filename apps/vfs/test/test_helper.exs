ExUnit.start()

# Setup test database
Ecto.Adapters.SQL.Sandbox.mode(VFS.Repo, :manual)
