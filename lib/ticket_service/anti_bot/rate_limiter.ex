defmodule TicketService.AntiBot.RateLimiter do
  @moduledoc """
  ETS-backed sliding window rate limiter.

  Tracks request counts per key (IP or session) using a sliding window
  implemented with ETS counters. Configurable per-endpoint limits.

  ## Configuration

      config :ticket_service, TicketService.AntiBot.RateLimiter,
        default_limit: 60,           # requests per window
        default_window_ms: 60_000,   # 1 minute window
        endpoints: %{
          "cart_add" => %{limit: 30, window_ms: 60_000},
          "checkout" => %{limit: 10, window_ms: 60_000}
        }
  """
  use GenServer

  @default_limit 60
  @default_window_ms 60_000
  @cleanup_interval_ms 120_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if a request is allowed for the given key and endpoint.

  Returns `:ok` or `{:error, :rate_limited, retry_after_ms}`.
  """
  def check(key, endpoint \\ "default") do
    config = get_endpoint_config(endpoint)
    bucket = bucket_key(key, endpoint)
    now = System.monotonic_time(:millisecond)
    window_start = now - config.window_ms

    case :ets.lookup(:rate_limiter, bucket) do
      [] ->
        :ets.insert(:rate_limiter, {bucket, [{now, 1}]})
        :ok

      [{^bucket, entries}] ->
        # Filter to current window
        current = Enum.filter(entries, fn {ts, _} -> ts > window_start end)
        count = Enum.reduce(current, 0, fn {_, c}, acc -> acc + c end)

        if count < config.limit do
          updated = [{now, 1} | current]
          :ets.insert(:rate_limiter, {bucket, updated})
          :ok
        else
          # Calculate retry-after from oldest entry in window
          oldest = current |> Enum.map(fn {ts, _} -> ts end) |> Enum.min(fn -> now end)
          retry_after = max(oldest + config.window_ms - now, 1000)
          {:error, :rate_limited, retry_after}
        end
    end
  end

  @doc "Reset rate limit for a key (for testing)."
  def reset(key, endpoint \\ "default") do
    bucket = bucket_key(key, endpoint)
    :ets.delete(:rate_limiter, bucket)
    :ok
  end

  @doc "Get current request count for a key."
  def current_count(key, endpoint \\ "default") do
    config = get_endpoint_config(endpoint)
    bucket = bucket_key(key, endpoint)
    now = System.monotonic_time(:millisecond)
    window_start = now - config.window_ms

    case :ets.lookup(:rate_limiter, bucket) do
      [] -> 0
      [{_, entries}] ->
        entries
        |> Enum.filter(fn {ts, _} -> ts > window_start end)
        |> Enum.reduce(0, fn {_, c}, acc -> acc + c end)
    end
  end

  # --- GenServer ---

  @impl true
  def init(_opts) do
    table = :ets.new(:rate_limiter, [:set, :public, :named_table, read_concurrency: true])
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)
    max_window = @default_window_ms * 2

    :ets.foldl(
      fn {key, entries}, _acc ->
        current = Enum.filter(entries, fn {ts, _} -> ts > now - max_window end)

        if current == [] do
          :ets.delete(:rate_limiter, key)
        else
          :ets.insert(:rate_limiter, {key, current})
        end
      end,
      nil,
      :rate_limiter
    )

    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
    {:noreply, state}
  end

  # --- Private ---

  defp bucket_key(key, endpoint), do: {key, endpoint}

  defp get_endpoint_config(endpoint) do
    config = Application.get_env(:ticket_service, __MODULE__, [])
    endpoints = Keyword.get(config, :endpoints, %{})

    case Map.get(endpoints, endpoint) do
      %{limit: limit, window_ms: window_ms} -> %{limit: limit, window_ms: window_ms}
      _ -> %{
        limit: Keyword.get(config, :default_limit, @default_limit),
        window_ms: Keyword.get(config, :default_window_ms, @default_window_ms)
      }
    end
  end
end
