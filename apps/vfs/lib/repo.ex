defmodule VFS.Repo do
  use Ecto.Repo,
    otp_app: :vfs,
    adapter: Ecto.Adapters.SQLite3
end
