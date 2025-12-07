defmodule SyncEngine.HealthCheck do
  @moduledoc """
  Health check module for monitoring system status.
  Provides diagnostics for database, job queue, and API connectivity.
  """

  alias VFS.Repo
  alias SyncEngine.JobQueue

  @doc """
  Performs a comprehensive health check of all system components.

  Returns:
    - `{:ok, %{status: :healthy, checks: map()}}` - All systems operational
    - `{:error, %{status: :unhealthy, checks: map()}}` - One or more systems failing
  """
  def check do
    checks = %{
      database: check_database(),
      job_queue: check_job_queue(),
      config: check_config()
    }

    overall_status =
      if Enum.all?(checks, fn {_key, result} -> result.status == :ok end) do
        :healthy
      else
        :unhealthy
      end

    result = %{
      status: overall_status,
      timestamp: DateTime.utc_now(),
      checks: checks
    }

    case overall_status do
      :healthy -> {:ok, result}
      :unhealthy -> {:error, result}
    end
  end

  @doc """
  Simple health check that returns :ok if system is operational.
  """
  def ping do
    case check() do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :unhealthy}
    end
  end

  # Private Functions

  defp check_database do
    try do
      # Try a simple query to verify database connectivity
      case Repo.query("SELECT 1 as health_check") do
        {:ok, %{num_rows: 1}} ->
          %{
            status: :ok,
            message: "Database operational",
            connected: true
          }

        _ ->
          %{
            status: :error,
            message: "Database query failed",
            connected: false
          }
      end
    rescue
      error ->
        %{
          status: :error,
          message: "Database connection error: #{inspect(error)}",
          connected: false
        }
    end
  end

  defp check_job_queue do
    try do
      # Check if JobQueue process is alive
      case Process.whereis(SyncEngine.JobQueue) do
        pid when is_pid(pid) ->
          queue_info = JobQueue.status()

          %{
            status: :ok,
            message: "Job queue operational",
            alive: true,
            pending_jobs: queue_info.pending,
            failed_jobs: queue_info.failed
          }

        nil ->
          %{
            status: :error,
            message: "Job queue process not running",
            alive: false
          }
      end
    rescue
      error ->
        %{
          status: :error,
          message: "Job queue check error: #{inspect(error)}",
          alive: false
        }
    end
  end

  defp check_config do
    rd_token = Application.get_env(:sync_engine, :real_debrid_token)
    rd_password = Application.get_env(:sync_engine, :real_debrid_webdav_password)

    config_valid = not is_nil(rd_token) and not is_nil(rd_password)

    if config_valid do
      %{
        status: :ok,
        message: "Configuration valid",
        rd_token_set: true,
        rd_password_set: true
      }
    else
      %{
        status: :error,
        message: "Missing required configuration",
        rd_token_set: not is_nil(rd_token),
        rd_password_set: not is_nil(rd_password)
      }
    end
  end
end
