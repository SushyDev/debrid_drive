defmodule SyncEngine.Schemas.RejectedTorrent do
  @moduledoc """
  Schema for tracking torrents that failed to sync and should not be retried.

  Torrents are marked as rejected when they consistently fail due to:
  - Mismatched file counts and download links
  - Invalid or corrupted torrent data
  - Repeated sync failures

  This prevents the system from repeatedly attempting to sync known-bad torrents.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "rejected_torrents" do
    # Real Debrid fields
    field(:rd_id, :string)
    field(:filename, :string)
    field(:hash, :string)

    # Rejection details
    field(:reason, :string)
    field(:error_details, :string)
    field(:attempt_count, :integer, default: 1)
    field(:last_attempted_at, :utc_datetime)

    timestamps()
  end

  @doc false
  def changeset(rejected_torrent, attrs) do
    rejected_torrent
    |> cast(attrs, [
      :rd_id,
      :filename,
      :hash,
      :reason,
      :error_details,
      :attempt_count,
      :last_attempted_at
    ])
    |> validate_required([:rd_id, :filename, :reason])
    |> unique_constraint(:rd_id)
  end

  @doc """
  Creates a changeset for a newly rejected torrent.
  """
  def reject_changeset(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> put_change(:last_attempted_at, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @doc """
  Increments the attempt count and updates last attempted time.
  """
  def increment_attempts(rejected_torrent) do
    rejected_torrent
    |> change(%{
      attempt_count: rejected_torrent.attempt_count + 1,
      last_attempted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end
end
