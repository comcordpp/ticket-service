defmodule TicketService.AntiBot.Detector do
  @moduledoc """
  Bot detection engine using browser fingerprinting, velocity checks, and anomaly scoring.

  Tracks session behavior across multiple signals and produces a risk score.
  High-score sessions are flagged for CAPTCHA challenge; very high scores are blocked.

  ## Scoring Signals

  | Signal                    | Weight | Description                           |
  |---------------------------|--------|---------------------------------------|
  | Missing user-agent        | +30    | No UA header                          |
  | Known bot UA              | +50    | Matches bot UA patterns               |
  | Request velocity          | +20    | >10 requests in 10 seconds            |
  | Cart velocity             | +25    | >5 cart adds in 30 seconds            |
  | Missing fingerprint       | +15    | No browser fingerprint submitted      |
  | Duplicate fingerprint     | +20    | Same fingerprint across sessions      |
  | Suspicious timing         | +10    | Sub-threshold ms between actions      |
  | Missing JS markers        | +15    | No JS execution confirmation          |
  | IP on watchlist           | +40    | IP flagged by admin rules             |
  | High-risk event           | +10    | Event flagged as high-risk            |

  Score thresholds (configurable):
  - 0-30: Normal
  - 31-60: Elevated (monitoring)
  - 61+: High risk (CAPTCHA required)
  - 90+: Blocked

  ## Configuration

      config :ticket_service, TicketService.AntiBot.Detector,
        captcha_threshold: 60,
        block_threshold: 90,
        velocity_threshold_ms: 500,
        session_ttl_ms: 1_800_000
  """
  use GenServer

  require Logger

  @captcha_threshold 60
  @block_threshold 90
  @velocity_threshold_ms 500
  @session_ttl_ms :timer.minutes(30)
  @cleanup_interval_ms :timer.minutes(5)
  @fingerprint_ttl_ms :timer.minutes(60)

  @known_bot_patterns [
    ~r/bot/i, ~r/crawler/i, ~r/spider/i, ~r/scraper/i,
    ~r/headless/i, ~r/phantom/i, ~r/selenium/i, ~r/puppeteer/i
  ]

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Analyze a request and return a risk assessment.

  Signals map:
  - `:user_agent` — User-Agent header value
  - `:fingerprint` — Browser fingerprint hash (from x-browser-fingerprint header)
  - `:accept_language` — Accept-Language header
  - `:screen_resolution` — Screen resolution (from x-screen-resolution header)
  - `:js_executed` — Whether JS execution marker is present (boolean)
  - `:ip` — Client IP address
  - `:event_id` — Event ID if applicable (for high-risk event checks)

  Returns `{:ok, :pass}`, `{:ok, :captcha_required, score}`, or `{:ok, :blocked, score}`.
  """
  def analyze(session_id, signals) do
    GenServer.call(__MODULE__, {:analyze, session_id, signals})
  end

  @doc "Submit a CAPTCHA verification result using the configured provider."
  def verify_captcha(session_id, captcha_token, remote_ip \\ nil) do
    GenServer.call(__MODULE__, {:verify_captcha, session_id, captcha_token, remote_ip})
  end

  @doc "Get the current risk score for a session."
  def get_score(session_id) do
    GenServer.call(__MODULE__, {:get_score, session_id})
  end

  @doc "Record a cart action for velocity tracking."
  def record_cart_action(session_id) do
    GenServer.cast(__MODULE__, {:record_cart_action, session_id})
  end

  @doc "Get bot detection statistics."
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @doc "Add or update a detection rule."
  def add_rule(rule) do
    GenServer.call(__MODULE__, {:add_rule, rule})
  end

  @doc "List all active detection rules."
  def list_rules do
    GenServer.call(__MODULE__, :list_rules)
  end

  @doc "Delete a detection rule by ID."
  def delete_rule(rule_id) do
    GenServer.call(__MODULE__, {:delete_rule, rule_id})
  end

  @doc "Get the audit log of recent detection decisions."
  def get_audit_log(opts \\ []) do
    GenServer.call(__MODULE__, {:get_audit_log, opts})
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    # ETS table for fingerprint-to-sessions mapping (cross-session correlation)
    :ets.new(:bot_fingerprints, [:set, :public, :named_table, read_concurrency: true])
    # ETS table for audit log
    :ets.new(:bot_audit_log, [:ordered_set, :public, :named_table, write_concurrency: true])

    Process.send_after(self(), :cleanup, @cleanup_interval_ms)

    {:ok,
     %{
       sessions: %{},
       rules: %{},
       stats: %{
         total_analyzed: 0,
         passed: 0,
         captcha_challenged: 0,
         blocked: 0,
         captcha_verified: 0,
         false_positives: 0
       }
     }}
  end

  @impl true
  def handle_call({:analyze, session_id, signals}, _from, state) do
    now = System.monotonic_time(:millisecond)

    session =
      Map.get(state.sessions, session_id, new_session(now))
      |> record_request(now)

    # Compute fingerprint hash from composite signals
    fingerprint = compute_fingerprint(signals)
    session = %{session | fingerprint: fingerprint}

    # Track fingerprint across sessions in ETS
    dup_fingerprint = track_fingerprint(fingerprint, session_id, now)

    score = calculate_score(session, signals, state.rules, dup_fingerprint)
    session = %{session | score: score, last_request_at: now}

    config = Application.get_env(:ticket_service, __MODULE__, [])
    captcha_thresh = Keyword.get(config, :captcha_threshold, @captcha_threshold)
    block_thresh = Keyword.get(config, :block_threshold, @block_threshold)

    {result, stats_key} =
      cond do
        score >= block_thresh ->
          {{:ok, :blocked, score}, :blocked}

        score >= captcha_thresh and not session.captcha_verified ->
          {{:ok, :captcha_required, score}, :captcha_challenged}

        true ->
          {{:ok, :pass}, :passed}
      end

    # Audit log
    log_decision(session_id, signals, score, result, now)

    state = %{
      state
      | sessions: Map.put(state.sessions, session_id, session),
        stats: update_stats(state.stats, stats_key)
    }

    {:reply, result, state}
  end

  @impl true
  def handle_call({:verify_captcha, session_id, captcha_token, remote_ip}, _from, state) do
    alias TicketService.AntiBot.CaptchaProvider

    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, {:error, :session_not_found}, state}

      session ->
        case CaptchaProvider.verify(captcha_token, remote_ip) do
          :ok ->
            session = %{session | captcha_verified: true, score: max(session.score - 30, 0)}
            state = %{state | sessions: Map.put(state.sessions, session_id, session)}
            stats = Map.update!(state.stats, :captcha_verified, &(&1 + 1))
            {:reply, :ok, %{state | stats: stats}}

          {:error, :invalid_token} ->
            {:reply, {:error, :invalid_token}, state}

          {:error, :provider_error, reason} ->
            Logger.error("CAPTCHA provider error: #{inspect(reason)}")
            {:reply, {:error, :provider_error}, state}
        end
    end
  end

  @impl true
  def handle_call({:get_score, session_id}, _from, state) do
    score =
      case Map.get(state.sessions, session_id) do
        nil -> 0
        session -> session.score
      end

    {:reply, score, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    active_sessions = map_size(state.sessions)

    elevated =
      Enum.count(state.sessions, fn {_, s} ->
        s.score > 30 and s.score < @captcha_threshold
      end)

    high_risk =
      Enum.count(state.sessions, fn {_, s} -> s.score >= @captcha_threshold end)

    stats =
      Map.merge(state.stats, %{
        active_sessions: active_sessions,
        elevated_sessions: elevated,
        high_risk_sessions: high_risk,
        active_rules: map_size(state.rules)
      })

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:add_rule, rule}, _from, state) do
    rule_id = Map.get(rule, :id, generate_rule_id())

    validated_rule = %{
      id: rule_id,
      type: Map.get(rule, :type, :ip_watchlist),
      value: Map.fetch!(rule, :value),
      weight: Map.get(rule, :weight, 40),
      description: Map.get(rule, :description, ""),
      created_at: DateTime.utc_now()
    }

    rules = Map.put(state.rules, rule_id, validated_rule)
    {:reply, {:ok, validated_rule}, %{state | rules: rules}}
  end

  @impl true
  def handle_call(:list_rules, _from, state) do
    {:reply, Map.values(state.rules), state}
  end

  @impl true
  def handle_call({:delete_rule, rule_id}, _from, state) do
    if Map.has_key?(state.rules, rule_id) do
      {:reply, :ok, %{state | rules: Map.delete(state.rules, rule_id)}}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call({:get_audit_log, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)

    entries =
      :ets.tab2list(:bot_audit_log)
      |> Enum.sort_by(fn {ts, _} -> ts end, :desc)
      |> Enum.take(limit)
      |> Enum.map(fn {_ts, entry} -> entry end)

    {:reply, entries, state}
  end

  @impl true
  def handle_cast({:record_cart_action, session_id}, state) do
    now = System.monotonic_time(:millisecond)

    session =
      Map.get(state.sessions, session_id, new_session(now))
      |> record_cart_action_ts(now)

    state = %{state | sessions: Map.put(state.sessions, session_id, session)}
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.monotonic_time(:millisecond)
    session_ttl = get_config(:session_ttl_ms, @session_ttl_ms)
    cutoff = now - session_ttl

    sessions =
      Map.filter(state.sessions, fn {_, s} -> s.last_request_at > cutoff end)

    # Clean up old fingerprint entries
    fp_cutoff = now - @fingerprint_ttl_ms

    :ets.foldl(
      fn {fp, sessions_map}, _acc ->
        cleaned = Map.filter(sessions_map, fn {_, ts} -> ts > fp_cutoff end)

        if map_size(cleaned) == 0 do
          :ets.delete(:bot_fingerprints, fp)
        else
          :ets.insert(:bot_fingerprints, {fp, cleaned})
        end
      end,
      nil,
      :bot_fingerprints
    )

    # Clean up old audit log entries (keep last 1000)
    audit_count = :ets.info(:bot_audit_log, :size)

    if audit_count > 1000 do
      entries = :ets.tab2list(:bot_audit_log) |> Enum.sort_by(fn {ts, _} -> ts end)
      to_delete = Enum.take(entries, audit_count - 1000)
      Enum.each(to_delete, fn {ts, _} -> :ets.delete(:bot_audit_log, ts) end)
    end

    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
    {:noreply, %{state | sessions: sessions}}
  end

  # --- Private ---

  defp new_session(now) do
    %{
      score: 0,
      request_times: [],
      cart_action_times: [],
      fingerprint: nil,
      captcha_verified: false,
      first_seen_at: now,
      last_request_at: now
    }
  end

  defp record_request(session, now) do
    times = [now | Enum.take(session.request_times, 19)]
    %{session | request_times: times, last_request_at: now}
  end

  defp record_cart_action_ts(session, now) do
    times = [now | Enum.take(session.cart_action_times, 19)]
    %{session | cart_action_times: times}
  end

  defp compute_fingerprint(signals) do
    ua = Map.get(signals, :user_agent, "")
    accept_lang = Map.get(signals, :accept_language, "")
    screen_res = Map.get(signals, :screen_resolution, "")
    explicit_fp = Map.get(signals, :fingerprint)

    # Use explicit fingerprint if provided, otherwise compute from headers
    if explicit_fp do
      explicit_fp
    else
      raw = "#{ua}|#{accept_lang}|#{screen_res}"
      if raw == "||", do: nil, else: :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
    end
  end

  defp track_fingerprint(nil, _session_id, _now), do: false

  defp track_fingerprint(fingerprint, session_id, now) do
    case :ets.lookup(:bot_fingerprints, fingerprint) do
      [] ->
        :ets.insert(:bot_fingerprints, {fingerprint, %{session_id => now}})
        false

      [{^fingerprint, sessions_map}] ->
        other_sessions = Map.delete(sessions_map, session_id)
        updated = Map.put(sessions_map, session_id, now)
        :ets.insert(:bot_fingerprints, {fingerprint, updated})
        map_size(other_sessions) > 0
    end
  end

  defp calculate_score(session, signals, rules, dup_fingerprint) do
    score = 0

    # Missing or bot user-agent
    user_agent = Map.get(signals, :user_agent, "")

    score =
      score +
        cond do
          is_nil(user_agent) or user_agent == "" -> 30
          Enum.any?(@known_bot_patterns, &Regex.match?(&1, user_agent)) -> 50
          true -> 0
        end

    # Missing fingerprint
    fingerprint = compute_fingerprint(signals)
    score = if is_nil(fingerprint), do: score + 15, else: score

    # Duplicate fingerprint across sessions
    score = if dup_fingerprint, do: score + 20, else: score

    # Missing JS execution marker
    js_executed = Map.get(signals, :js_executed, false)
    score = if js_executed, do: score, else: score + 15

    # Request velocity: >10 in 10 seconds
    now = System.monotonic_time(:millisecond)
    recent_requests = Enum.count(session.request_times, &(&1 > now - 10_000))
    score = if recent_requests > 10, do: score + 20, else: score

    # Cart velocity: >5 in 30 seconds
    recent_cart = Enum.count(session.cart_action_times, &(&1 > now - 30_000))
    score = if recent_cart > 5, do: score + 25, else: score

    # Suspicious timing: sub-threshold between requests
    velocity_thresh = get_config(:velocity_threshold_ms, @velocity_threshold_ms)

    score =
      case session.request_times do
        [latest, prev | _] when latest - prev < velocity_thresh -> score + 10
        _ -> score
      end

    # Apply admin rules
    score = apply_rules(score, signals, rules)

    score
  end

  defp apply_rules(score, signals, rules) do
    Enum.reduce(rules, score, fn {_id, rule}, acc ->
      if rule_matches?(rule, signals), do: acc + rule.weight, else: acc
    end)
  end

  defp rule_matches?(%{type: :ip_watchlist, value: ip}, signals) do
    Map.get(signals, :ip) == ip
  end

  defp rule_matches?(%{type: :ua_pattern, value: pattern}, signals) do
    ua = Map.get(signals, :user_agent, "")

    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, ua || "")
      _ -> false
    end
  end

  defp rule_matches?(%{type: :fingerprint_block, value: fp}, signals) do
    Map.get(signals, :fingerprint) == fp
  end

  defp rule_matches?(%{type: :high_risk_event, value: event_id}, signals) do
    Map.get(signals, :event_id) == event_id
  end

  defp rule_matches?(_, _), do: false

  defp log_decision(session_id, signals, score, result, now) do
    decision =
      case result do
        {:ok, :pass} -> :pass
        {:ok, :captcha_required, _} -> :captcha_required
        {:ok, :blocked, _} -> :blocked
      end

    entry = %{
      session_id: session_id,
      score: score,
      decision: decision,
      ip: Map.get(signals, :ip),
      user_agent: Map.get(signals, :user_agent),
      fingerprint: compute_fingerprint(signals),
      timestamp: DateTime.utc_now()
    }

    :ets.insert(:bot_audit_log, {now, entry})

    case decision do
      :blocked ->
        Logger.warning("Bot detection: session #{session_id} blocked (score: #{score})")

      :captcha_required ->
        Logger.info("Bot detection: session #{session_id} captcha required (score: #{score})")

      :pass ->
        :ok
    end
  end

  defp update_stats(stats, key) do
    stats
    |> Map.update!(:total_analyzed, &(&1 + 1))
    |> Map.update!(key, &(&1 + 1))
  end

  defp get_config(key, default) do
    config = Application.get_env(:ticket_service, __MODULE__, [])
    Keyword.get(config, key, default)
  end

  defp generate_rule_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end
end
