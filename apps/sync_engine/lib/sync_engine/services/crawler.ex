defmodule SyncEngine.Services.Crawler do
  @moduledoc """
  Fetches a URL, extracts specific HTML element content, and returns its SHA256 hash.
  Includes retry logic, timeouts, and comprehensive error handling.
  """

  require Logger

  @default_timeout :timer.seconds(30)
  @default_max_retries 3
  @default_retry_delay :timer.seconds(1)

  @doc """
  Create new client with URL and options
  """
  @spec new_client(String.t(), keyword()) :: Req.Request.t()
  def new_client(url, opts \\ []) when is_binary(url) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    retry_delay = Keyword.get(opts, :retry_delay, @default_retry_delay)

    Req.new(
      url: url,
      method: :get,
      headers: [
        {"user-agent", ""},
        {"connection", "keep-alive"},
        {"cache-control", "no-cache"}
      ],
      compressed: true,
      connect_options: [timeout: timeout],
      receive_timeout: timeout,
      retry: :transient,
      max_retries: max_retries,
      retry_delay: fn attempt -> attempt * retry_delay end,
      retry_log_level: :warning
    )
  end

  @doc """
  Fetches the page and returns the SHA256 hash of the specified element's inner HTML.
  Takes a URL string directly or a Req client struct.
  """
  @spec get_hash(Req.Request.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def get_hash(%Req.Request{} = client, element_tag \\ "table", _opts \\ [])
      when not is_nil(client) and is_binary(element_tag) do
    Logger.debug("#{__MODULE__} fetching URL: #{client.url}")
    start_time = System.monotonic_time(:millisecond)

    result =
      with {:ok, %{status: status, body: body}} when status in 200..299 <- Req.request(client),
           {:ok, document} <- parse_body(body),
           {:ok, element} <- find_element(document, element_tag),
           {:ok, hash} <- hash_element(element) do
        duration = System.monotonic_time(:millisecond) - start_time
        Logger.debug("#{__MODULE__} successfully fetched and hashed in #{duration}ms")

        :telemetry.execute(
          [:sync_engine, :crawler, :fetch],
          %{duration: duration},
          %{status: :success, url: to_string(client.url)}
        )

        {:ok, hash}
      else
        {:ok, %{status: status}} ->
          error = {:http_error, status}
          Logger.warning("#{__MODULE__} HTTP error: #{status}")

          :telemetry.execute(
            [:sync_engine, :crawler, :fetch],
            %{duration: System.monotonic_time(:millisecond) - start_time},
            %{status: :error, reason: :http_error, http_status: status}
          )

          {:error, error}

        {:error, reason} = error ->
          Logger.warning("#{__MODULE__} request failed: #{inspect(reason)}")

          :telemetry.execute(
            [:sync_engine, :crawler, :fetch],
            %{duration: System.monotonic_time(:millisecond) - start_time},
            %{status: :error, reason: reason}
          )

          error
      end

    result
  rescue
    exception ->
      Logger.error("#{__MODULE__} unexpected error: #{Exception.format(:error, exception)}")
      {:error, {:exception, exception}}
  end

  # --- Internal Functions ---

  defp parse_body(body) when is_binary(body) do
    case Floki.parse_document(body) do
      {:ok, document} ->
        {:ok, document}

      {:error, reason} ->
        Logger.warning("#{__MODULE__} failed to parse HTML: #{inspect(reason)}")
        {:error, {:parse_error, reason}}
    end
  end

  defp find_element(document, element_tag) when is_binary(element_tag) do
    case Floki.find(document, element_tag) do
      [{_tag, _attrs, children} | _] ->
        {:ok, children}

      [] ->
        Logger.warning("#{__MODULE__} element '#{element_tag}' not found in document")
        {:error, {:element_not_found, element_tag}}
    end
  end

  defp hash_element(element) do
    case Floki.raw_html(element) do
      "" ->
        Logger.warning("#{__MODULE__} element content is empty")
        {:error, :empty_element}

      html_string ->
        hash = :crypto.hash(:sha256, html_string) |> Base.encode16(case: :lower)
        {:ok, hash}
    end
  end
end
