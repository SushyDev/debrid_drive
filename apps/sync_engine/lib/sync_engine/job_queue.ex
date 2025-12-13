defmodule SyncEngine.JobQueue do
  @moduledoc """
  A simple GenServer-based job queue for asynchronous torrent operations.

  Replaces Oban with a lighter-weight solution that:
  - Processes jobs sequentially to avoid SQLite contention
  - Retries failed jobs with exponential backoff
  - Works with the rate-limited RealDebrid client
  - Survives restarts by tracking job state in the torrents table

  ## Job Types

  - `:add_torrent` - Add a new torrent to VFS (queued from sync)
  - `:delete_torrent` - Delete a torrent from Real-Debrid API and cleanup VFS

  ## Usage

      # Enqueue a deletion
      SyncEngine.JobQueue.enqueue(:delete_torrent, %{torrent_id: 123})

      # Get queue status
      SyncEngine.JobQueue.status()
  """

  use GenServer
  require Logger

  @max_retries 3
  @initial_retry_delay :timer.seconds(5)
  @max_retry_delay :timer.minutes(5)

  defstruct queue: :queue.new(),
            processing: nil,
            stats: %{processed: 0, succeeded: 0, failed: 0}

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Enqueues a job for async processing.

  ## Examples

      JobQueue.enqueue(:delete_torrent, %{torrent_id: 123})
      JobQueue.enqueue(:add_torrent, %{rd_torrent: torrent_data, torrents_root_id: 1})
  """
  def enqueue(job_type, args) when is_atom(job_type) and is_map(args) do
    GenServer.cast(__MODULE__, {:enqueue, job_type, args})
  end

  @doc """
  Returns the current queue status.
  """
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Clears all pending jobs (useful for testing).
  """
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    Logger.info("#{__MODULE__} starting")

    # Schedule recovery of pending jobs from database on startup
    send(self(), :recover_pending_jobs)

    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_cast({:enqueue, job_type, args}, state) do
    job = %{
      type: job_type,
      args: args,
      retry_count: 0,
      enqueued_at: System.monotonic_time(:millisecond)
    }

    new_queue = :queue.in(job, state.queue)
    new_state = %{state | queue: new_queue}

    Logger.debug("#{__MODULE__} enqueued #{job_type}: #{inspect(args)}")

    # Process immediately if not currently processing
    if is_nil(state.processing) do
      send(self(), :process_next)
    end

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    queue_length = :queue.len(state.queue)

    status = %{
      queue_length: queue_length,
      processing: state.processing,
      stats: state.stats
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:process_next, %{processing: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, job}, new_queue} ->
        # Mark as processing
        new_state = %{state | queue: new_queue, processing: job}

        # Process in a Task to not block the GenServer
        task = Task.async(fn -> process_job(job) end)

        # Store task ref in state
        new_state = Map.put(new_state, :current_task, task)

        {:noreply, new_state}

      {:empty, _queue} ->
        # Nothing to process
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:process_next, state) do
    # Already processing, ignore
    {:noreply, state}
  end

  @impl true
  def handle_info(:recover_pending_jobs, state) do
    Logger.info("#{__MODULE__} recovering pending jobs from database")

    # Recover pending deletions
    pending_deletions = SyncEngine.Torrents.list_pending_deletions()

    Enum.each(pending_deletions, fn torrent ->
      enqueue(:delete_torrent, %{torrent_id: torrent.id})
    end)

    if length(pending_deletions) > 0 do
      Logger.info("#{__MODULE__} recovered #{length(pending_deletions)} pending deletion jobs")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({ref, result}, %{current_task: %Task{ref: ref}} = state) do
    # Task completed
    Process.demonitor(ref, [:flush])

    job = state.processing

    new_state =
      case result do
        :ok ->
          Logger.debug("#{__MODULE__} job completed successfully: #{job.type}")

          %{
            state
            | processing: nil,
              stats: %{
                state.stats
                | processed: state.stats.processed + 1,
                  succeeded: state.stats.succeeded + 1
              }
          }
          |> Map.delete(:current_task)

        {:error, reason} ->
          handle_job_failure(state, job, reason)
      end

    # Process next job
    send(self(), :process_next)

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{current_task: %Task{ref: ref}} = state) do
    # Task crashed
    Logger.error("#{__MODULE__} job task crashed: #{inspect(reason)}")

    job = state.processing
    new_state = handle_job_failure(state, job, reason)

    # Process next job
    send(self(), :process_next)

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:retry_job, job}, state) do
    # Re-enqueue the job
    new_queue = :queue.in(job, state.queue)
    send(self(), :process_next)
    {:noreply, %{state | queue: new_queue}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("#{__MODULE__} terminating: #{inspect(reason)}")

    # Cancel current task if processing
    if state.processing && Map.has_key?(state, :current_task) do
      task = state.current_task
      Logger.info("#{__MODULE__} waiting for current job to complete...")

      # Give the task 5 seconds to finish
      case Task.yield(task, 5000) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          Logger.info("#{__MODULE__} current job completed: #{inspect(result)}")

        nil ->
          Logger.warning("#{__MODULE__} current job did not complete in time, killed")
      end
    end

    # Log pending jobs
    queue_length = :queue.len(state.queue)

    if queue_length > 0 do
      Logger.warning(
        "#{__MODULE__} shutting down with #{queue_length} pending jobs - they will be recovered on restart"
      )
    end

    Logger.info("#{__MODULE__} terminated gracefully")
    :ok
  end

  ## Private Functions

  defp process_job(%{type: :delete_torrent, args: %{torrent_id: torrent_id}}) do
    Logger.info("#{__MODULE__} processing deletion for torrent_id=#{torrent_id}")

    case SyncEngine.Torrents.get_torrent(torrent_id) do
      {:ok, torrent} ->
        client = SyncEngine.RealDebridClient.get_client()

        # Call API deletion directly
        result = RealDebrid.Api.Delete.delete(client, torrent.rd_id)

        case result do
          :ok ->
            Logger.info("#{__MODULE__} deleted torrent #{torrent.rd_id} from API")
            SyncEngine.Torrents.cleanup_after_deletion(torrent_id, cascade_hardlinks: true)

          {:error, "Not found"} ->
            # Already deleted, just cleanup
            Logger.info("#{__MODULE__} torrent #{torrent.rd_id} already deleted, cleaning up")
            SyncEngine.Torrents.cleanup_after_deletion(torrent_id, cascade_hardlinks: true)

          {:error, reason} ->
            Logger.error(
              "#{__MODULE__} failed to delete torrent #{torrent.rd_id}: #{inspect(reason)}"
            )

            SyncEngine.Torrents.record_deletion_attempt(torrent, {:error, reason})
            {:error, reason}
        end

      {:error, :not_found} ->
        Logger.info("#{__MODULE__} torrent_id=#{torrent_id} not found, already deleted")
        :ok
    end
  end

  defp process_job(%{
         type: :add_torrent,
         args: %{rd_torrent: _rd_torrent, torrents_root_id: _torrents_root_id}
       }) do
    # TODO: Implement lazy torrent addition
    # For now, this is handled synchronously in TorrentSync
    Logger.warning("#{__MODULE__} add_torrent not yet implemented in async mode")
    :ok
  end

  defp handle_job_failure(state, job, reason) do
    if job.retry_count < @max_retries do
      # Retry with exponential backoff
      retry_count = job.retry_count + 1
      delay = calculate_retry_delay(retry_count)

      Logger.warning(
        "#{__MODULE__} job failed (attempt #{retry_count}/#{@max_retries}), retrying in #{delay}ms: #{inspect(reason)}"
      )

      # Re-enqueue with updated retry count
      retry_job = %{job | retry_count: retry_count}

      Process.send_after(self(), {:retry_job, retry_job}, delay)

      %{
        state
        | processing: nil,
          stats: %{state.stats | processed: state.stats.processed + 1}
      }
      |> Map.delete(:current_task)
    else
      # Max retries exceeded
      Logger.error(
        "#{__MODULE__} job failed after #{@max_retries} attempts, giving up: #{inspect(reason)}"
      )

      # record_deletion_attempt already marks as failed after max attempts
      # so we don't need to do it again here

      %{
        state
        | processing: nil,
          stats: %{
            state.stats
            | processed: state.stats.processed + 1,
              failed: state.stats.failed + 1
          }
      }
      |> Map.delete(:current_task)
    end
  end

  defp calculate_retry_delay(retry_count) do
    delay = @initial_retry_delay * :math.pow(2, retry_count - 1)
    min(round(delay), @max_retry_delay)
  end
end
