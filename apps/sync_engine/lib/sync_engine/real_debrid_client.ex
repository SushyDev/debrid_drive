defmodule SyncEngine.RealDebridClient do
  @moduledoc """
  A GenServer that maintains a single shared RealDebrid API client.

  This ensures all API calls across the application use the same client instance,
  which allows the built-in rate limiting in RealDebrid.Client to work properly
  across all processes.

  ## Configuration

  The following application environment variables are used:
    * `:real_debrid_token` - The RealDebrid API token
    * `:real_debrid_max_requests_per_minute` - Max API calls per minute (default: 50)

  ## Usage

      # Get the shared client
      client = SyncEngine.RealDebridClient.get_client()
      
      # Use it with any RealDebrid API module
      RealDebrid.Api.Torrents.list(client)
  """

  use GenServer
  require Logger

  @default_max_requests_per_minute 50

  ## Client API

  @doc """
  Starts the RealDebridClient GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets the shared RealDebrid client.

  This client should be used for all RealDebrid API calls to ensure
  the built-in rate limiting works properly across all processes.
  """
  @spec get_client() :: RealDebrid.Client.t()
  def get_client do
    GenServer.call(__MODULE__, :get_client)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    token = Application.get_env(:sync_engine, :real_debrid_token)

    if is_nil(token) or token == "" do
      Logger.warning("#{__MODULE__} started without RealDebrid token configured")
    end

    max_requests =
      Application.get_env(
        :sync_engine,
        :real_debrid_max_requests_per_minute,
        @default_max_requests_per_minute
      )

    client = create_client(token, max_requests)

    Logger.info("#{__MODULE__} started with shared client (max #{max_requests} requests/minute)")

    {:ok, %{client: client}}
  end

  @impl true
  def handle_call(:get_client, _from, state) do
    {:reply, state.client, state}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.info("#{__MODULE__} terminating: #{inspect(reason)}")
    :ok
  end

  ## Private Functions

  defp create_client(nil, _max_requests), do: nil
  defp create_client("", _max_requests), do: nil

  defp create_client(token, max_requests) do
    RealDebrid.Client.new(token, max_requests_per_minute: max_requests)
  end
end
