defmodule SyncEngine.Services.Poller do
  use GenServer
  require Logger

  @default_interval :timer.seconds(15)
  @interval Application.compile_env(:sync_engine, :poller_interval, @default_interval)
  @max_failures 5
  @backoff_multiplier 2
  @max_backoff :timer.minutes(5)

  defstruct client: nil,
            timer_ref: nil,
            hash: "",
            consecutive_failures: 0,
            current_interval: @interval,
            last_success: nil,
            last_error: nil

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def manual_poll do
    GenServer.cast(__MODULE__, :manual_poll)
  end

  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    Logger.info("#{__MODULE__} starting with interval: #{@interval}ms")

    client = get_url() |> SyncEngine.Services.Crawler.new_client()

    state = %__MODULE__{
      client: client,
      current_interval: @interval
    }

    # Don't block init, use handle_continue to run initial poll
    {:ok, state, {:continue, :initial_poll}}
  end

  @impl true
  def handle_continue(:initial_poll, state) do
    perform_poll_cycle(state)
  end

  @impl true
  def handle_info(:poll, state) do
    perform_poll_cycle(state)
  end

  @impl true
  def handle_info({:new_hash, _new_hash}, state) do
    Logger.info("#{__MODULE__} detected hash change, triggering sync")

    # Perform sync in background to not block the poller
    Task.start(fn -> perform_torrent_sync() end)

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @doc """
  Handle the manual poll
  """
  @impl true
  def handle_cast(:manual_poll, state) do
    Logger.info("#{__MODULE__} manual poll triggered")

    if state.timer_ref do
      case Process.cancel_timer(state.timer_ref) do
        # Flush the :poll message if it arrived exactly when we forced
        false -> flush_messages()
        _time_remaining -> :ok
      end
    end

    # Reset backoff on manual poll
    perform_poll_cycle(%{state | consecutive_failures: 0, current_interval: @interval})
  end

  # --- Helper Functions ---

  @spec get_url() :: String.t()
  defp get_url() do
    real_debrid_webdav_password = Application.get_env(:sync_engine, :real_debrid_webdav_password)

    "https://my.real-debrid.com/#{real_debrid_webdav_password}/torrents"
  end

  defp perform_poll_cycle(%__MODULE__{} = state) do
    start_time = System.monotonic_time(:millisecond)

    case perform_work(state) do
      {:ok, new_hash} ->
        duration = System.monotonic_time(:millisecond) - start_time
        Logger.debug("#{__MODULE__} poll completed in #{duration}ms")

        # Emit telemetry for successful poll
        :telemetry.execute(
          [:sync_engine, :poller, :poll],
          %{duration: duration, consecutive_failures: 0},
          %{status: :success}
        )

        new_state = %__MODULE__{
          state
          | hash: new_hash,
            consecutive_failures: 0,
            current_interval: @interval,
            last_success: DateTime.utc_now()
        }

        timer_ref = schedule_next_run(new_state.current_interval)
        {:noreply, %{new_state | timer_ref: timer_ref}}

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time
        new_failures = state.consecutive_failures + 1

        Logger.warning("#{__MODULE__} poll failed (attempt #{new_failures}/#{@max_failures}): #{inspect(reason)}")

        # Emit telemetry for failed poll
        :telemetry.execute(
          [:sync_engine, :poller, :poll],
          %{duration: duration, consecutive_failures: new_failures},
          %{status: :error, reason: reason}
        )

        # Calculate backoff interval
        new_interval = calculate_backoff_interval(new_failures)

        if new_failures >= @max_failures do
          Logger.error("#{__MODULE__} reached max failures (#{@max_failures}), using max backoff: #{new_interval}ms")
        end

        new_state = %__MODULE__{
          state
          | consecutive_failures: new_failures,
            current_interval: new_interval,
            last_error: {DateTime.utc_now(), reason}
        }

        timer_ref = schedule_next_run(new_interval)
        {:noreply, %{new_state | timer_ref: timer_ref}}
    end
  end

  defp perform_work(%__MODULE__{client: client, hash: hash}) when not is_nil(client) do
    case SyncEngine.Services.Crawler.get_hash(client) do
      {:ok, new_hash} ->
        if new_hash != hash do
          send(self(), {:new_hash, new_hash})
        end

        {:ok, new_hash}

      {:error, _reason} = error ->
        error
    end
  rescue
    exception ->
      Logger.error("#{__MODULE__} unexpected error: #{inspect(exception)}")
      {:error, exception}
  end

  defp calculate_backoff_interval(failures) when is_integer(failures) and failures > 0 do
    backoff = @interval * :math.pow(@backoff_multiplier, failures - 1)
    round(min(backoff, @max_backoff))
  end

  defp flush_messages do
    receive do
      :poll -> flush_messages()
    after
      0 -> :ok
    end
  end

  defp schedule_next_run(interval) when is_integer(interval) and interval > 0 do
    Process.send_after(self(), :poll, interval)
  end

  defp perform_torrent_sync do
    Logger.info("#{__MODULE__} starting torrent sync")
    start_time = System.monotonic_time(:millisecond)

    try do
      # Get shared Real Debrid client with rate limiting
      client = SyncEngine.RealDebridClient.get_client()

      # Get or create torrents root directory in VFS
      torrents_root_id = ensure_torrents_root()

      # Perform sync
      case SyncEngine.Services.TorrentSync.sync(client, torrents_root_id: torrents_root_id) do
        {:ok, result} ->
          duration = System.monotonic_time(:millisecond) - start_time

          Logger.info(
            "#{__MODULE__} sync completed in #{duration}ms: " <>
              "#{result.added} added, #{result.removed} removed, #{length(result.errors)} errors"
          )

          # Emit telemetry for successful sync
          :telemetry.execute(
            [:sync_engine, :poller, :sync],
            %{
              duration: duration,
              added: result.added,
              removed: result.removed,
              errors: length(result.errors)
            },
            %{status: :success}
          )

          if length(result.errors) > 0 do
            Logger.warning("#{__MODULE__} sync had errors: #{inspect(result.errors)}")
          end

        {:error, reason} ->
          duration = System.monotonic_time(:millisecond) - start_time
          Logger.error("#{__MODULE__} sync failed after #{duration}ms: #{inspect(reason)}")

          # Emit telemetry for failed sync
          :telemetry.execute(
            [:sync_engine, :poller, :sync],
            %{duration: duration},
            %{status: :error, reason: reason}
          )
      end
    rescue
      exception ->
        duration = System.monotonic_time(:millisecond) - start_time

        Logger.error("#{__MODULE__} sync crashed after #{duration}ms: #{inspect(exception)}\n#{Exception.format_stacktrace()}")

        # Emit telemetry for crashed sync
        :telemetry.execute(
          [:sync_engine, :poller, :sync],
          %{duration: duration},
          %{status: :error, reason: exception}
        )
    end
  end

  defp ensure_torrents_root do
    container_name = Application.get_env(:sync_engine, :torrents_container_name, "media_manager")

    case VFS.get_root() do
      {:ok, root} ->
        case VFS.lookup(root.inode_id, container_name) do
          {:ok, node} ->
            node.inode_id

          {:error, :not_found} ->
            case VFS.create_directory(root.inode_id, container_name) do
              {:ok, node} ->
                Logger.info("#{__MODULE__} created #{container_name} directory")
                node.inode_id

              {:error, reason} ->
                Logger.error("#{__MODULE__} failed to create #{container_name} directory: #{inspect(reason)}")

                raise "Failed to create torrents root directory: #{inspect(reason)}"
            end
        end

      %VFS.Inode{} = root ->
        # Handle case where Repo.transact returns unwrapped result
        case VFS.lookup(root.inode_id, container_name) do
          {:ok, node} ->
            node.inode_id

          {:error, :not_found} ->
            case VFS.create_directory(root.inode_id, container_name) do
              {:ok, node} ->
                Logger.info("#{__MODULE__} created #{container_name} directory")
                node.inode_id

              {:error, reason} ->
                Logger.error("#{__MODULE__} failed to create #{container_name} directory: #{inspect(reason)}")

                raise "Failed to create torrents root directory: #{inspect(reason)}"
            end
        end

      {:error, reason} ->
        Logger.error("#{__MODULE__} failed to get VFS root: #{inspect(reason)}")
        raise "Failed to get VFS root: #{inspect(reason)}"
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("#{__MODULE__} terminating: #{inspect(reason)}")

    # Cancel pending timer
    if state.timer_ref do
      Process.cancel_timer(state.timer_ref)
      Logger.debug("#{__MODULE__} cancelled pending timer")
    end

    Logger.info("#{__MODULE__} terminated gracefully")
    :ok
  end
end
