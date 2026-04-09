defmodule TicketService.AntiBot.RateLimiter do
  @moduledoc """
  ETS-backed sliding window rate limiter with per-IP and per-session support.

  Tracks request counts per key (IP or session) using a sliding window
  implemented with ETS counters. Supports configurable per-endpoint limits,
  per-event overrides, and IP allowlist/blocklist.

  ## Configuration

      config :ticket_service, TicketService.AntiBot.RateLimiter,
        ip_limit: 60,               # per-IP requests per window
        ip_window_ms: 60_000,       # 1 minute window
        session_limit: 30,          # per-session requests per window
        session_window_ms: 60_000,  # 1 minute window
        endpoints: %{
          "cart_add" => %{ip_limit: 30, session_limit: 15, window_ms: 60_000},
          "checkout" => %{ip_limit: 10, session_limit: 5, window_ms: 60_000}
        },
        event_overrides: %{
          "event-uuid" => %{ip_limit: 20, session_limit: 10, window_ms: 60_000}
        },
        allowlist: ["127.0.0.1"],
        blocklist: []
  """
  use GenServer
  require Logger

  @default_ip_limit 60
  @default_session_limit 30
  @default_window_ms 60_000
  @cleanup_interval_ms 120_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Check if a request is allowed for the given key, endpoint, and optional event_id.

  Returns `{:ok, info}` or `{:error, :rate_limited, info}` where info contains
  limit, remaining, and reset_ms for response headers.
  """
  def check(key, endpoint \\ "default", opts \\ []) do
    event_id = Keyword.get(opts, :event_id)
    config = get_endpoint_config(endpoint, event_id)
    {limit, window_ms} = limits_for_key_type(key, config)
    bucket = bucket_key(key, endpoint)
    now = System.monotonic_time(:millisecond)
    window_start = now - window_ms

    case :ets.lookup(:rate_limiter, bucket) do
      [] ->
        :ets.insert(:rate_limiter, {bucket, [{now, 1}]})
        {:ok, %{limit: limit, remaining: limit - 1, reset_ms: window_ms}}

      [{^bucket, entries}] ->
        current = Enum.filter(entries, fn {ts, _} -> ts > window_start end)
        count = Enum.reduce(current, 0, fn {_, c}, acc -> acc + c end)

        if count < limit do
          updated = [{now, 1} | current]
          :ets.insert(:rate_limiter, {bucket, updated})
          {:ok, %{limit: limit, remaining: limit - count - 1, reset_ms: time_to_reset(current, window_ms, now)}}
        else
          oldest = current |> Enum.map(fn {ts, _} -> ts end) |> Enum.min(fn -> now end)
          retry_after = max(oldest + window_ms - now, 1000)
          {:error, :rate_limited, %{limit: limit, remaining: 0, reset_ms: retry_after, retry_after_ms: retry_after}}
        end
    end
  end

  @doc "Check if an IP is in the allowlist."
  def allowlisted?(ip) do
    config = Application.get_env(:ticket_service, __MODULE__, [])
    ip in Keyword.get(config, :allowlist, [])
  end

  @doc "Check if an IP is in the blocklist."
  def blocklisted?(ip) do
    config = Application.get_env(:ticket_service, __MODULE__, [])
    ip in Keyword.get(config, :blocklist, [])
  end

  @doc "Reset rate limit for a key (for testing)."
  def reset(key, endpoint \\ "default") do
    bucket = bucket_key(key, endpoint)
    :ets.delete(:rate_limiter, bucket)
    :ok
  end

  @doc "Get current request count for a key."
  def current_count(key, endpoint \\ "default") do
    config = get_endpoint_config(endpoint, nil)
    {_limit, window_ms} = limits_for_key_type(key, config)
    bucket = bucket_key(key, endpoint)
    now = System.monotonic_time(:millisecond)
    window_start = now - window_ms

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

  defp time_to_reset([], window_ms, _now), do: window_ms

  defp time_to_reset(entries, window_ms, now) do
    oldest = entries |> Enum.map(fn {ts, _} -> ts end) |> Enum.min()
    max(oldest + window_ms - now, 1000)
  end

  defp limits_for_key_type({:session, _}, config) do
    {config.session_limit, config.window_ms}
  end

  defp limits_for_key_type(_ip_key, config) do
    {config.ip_limit, config.window_ms}
  end

  defp get_endpoint_config(endpoint, event_id) do
    config = Application.get_env(:ticket_service, __MODULE__, [])

    # Check event-specific overrides first
    event_overrides = Keyword.get(config, :event_overrides, %{})

    base =
      if event_id && Map.has_key?(event_overrides, event_id) do
        Map.get(event_overrides, event_id)
      else
        endpoints = Keyword.get(config, :endpoints, %{})
        Map.get(endpoints, endpoint)
      end

    case base do
      %{ip_limit: ip_limit, session_limit: session_limit, window_ms: window_ms} ->
        %{ip_limit: ip_limit, session_limit: session_limit, window_ms: window_ms}

      %{ip_limit: ip_limit, session_limit: session_limit} ->
        %{
          ip_limit: ip_limit,
          session_limit: session_limit,
          window_ms: Keyword.get(config, :ip_window_ms, @default_window_ms)
        }

      # Legacy format support
      %{limit: limit, window_ms: window_ms} ->
        %{ip_limit: limit, session_limit: div(limit, 2), window_ms: window_ms}

      _ ->
        %{
          ip_limit: Keyword.get(config, :ip_limit, @default_ip_limit),
          session_limit: Keyword.get(config, :session_limit, @default_session_limit),
          window_ms: Keyword.get(config, :ip_window_ms, @default_window_ms)
        }
    end
  end
end
