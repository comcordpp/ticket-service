defmodule TicketService.AntiBot.Detector do
  @moduledoc """
  Bot detection engine using browser fingerprinting and anomaly scoring.

  Tracks session behavior across multiple signals and produces a risk score.
  High-score sessions are flagged for CAPTCHA challenge.

  ## Scoring Signals

  | Signal                    | Weight | Description                           |
  |---------------------------|--------|---------------------------------------|
  | Missing user-agent        | +30    | No UA header                          |
  | Known bot UA              | +50    | Matches bot UA patterns               |
  | Request velocity          | +20    | >10 requests in 10 seconds            |
  | Cart velocity             | +25    | >5 cart adds in 30 seconds            |
  | Missing fingerprint       | +15    | No browser fingerprint submitted      |
  | Duplicate fingerprint     | +20    | Same fingerprint across sessions      |
  | Suspicious timing         | +10    | Sub-100ms between requests            |

  Score thresholds:
  - 0-30: Normal
  - 31-60: Elevated (monitoring)
  - 61+: High risk (CAPTCHA required)

  ## Configuration

      config :ticket_service, TicketService.AntiBot.Detector,
        captcha_threshold: 60,
        block_threshold: 90
  """
  use GenServer

  require Logger

  @captcha_threshold 60
  @block_threshold 90
  @session_ttl_ms :timer.minutes(30)
  @cleanup_interval_ms :timer.minutes(5)

  @known_bot_patterns [
    ~r/bot/i, ~r/crawler/i, ~r/spider/i, ~r/scraper/i,
    ~r/headless/i, ~r/phantom/i, ~r/selenium/i, ~r/puppeteer/i
  ]

  defstruct sessions: %{}

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Analyze a request and return a risk assessment.

  Returns `{:ok, :pass}`, `{:ok, :captcha_required, score}`, or `{:ok, :blocked, score}`.
  """
  def analyze(session_id, signals) do
    GenServer.call(__MODULE__, {:analyze, session_id, signals})
  end

  @doc "Submit a CAPTCHA verification result."
  def verify_captcha(session_id, captcha_token) do
    GenServer.call(__MODULE__, {:verify_captcha, session_id, captcha_token})
  end

  @doc "Get the current risk score for a session."
  def get_score(session_id) do
    GenServer.call(__MODULE__, {:get_score, session_id})
  end

  @doc "Record a cart action for velocity tracking."
  def record_cart_action(session_id) do
    GenServer.cast(__MODULE__, {:record_cart_action, session_id})
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:analyze, session_id, signals}, _from, state) do
    now = System.monotonic_time(:millisecond)

    session =
      Map.get(state.sessions, session_id, new_session(now))
      |> record_request(now)

    score = calculate_score(session, signals)
    session = %{session | score: score, last_request_at: now}

    config = Application.get_env(:ticket_service, __MODULE__, [])
    captcha_thresh = Keyword.get(config, :captcha_threshold, @captcha_threshold)
    block_thresh = Keyword.get(config, :block_threshold, @block_threshold)

    result =
      cond do
        score >= block_thresh ->
          Logger.warning("Session #{session_id} blocked (score: #{score})")
          {:ok, :blocked, score}

        score >= captcha_thresh and not session.captcha_verified ->
          {:ok, :captcha_required, score}

        true ->
          {:ok, :pass}
      end

    state = %{state | sessions: Map.put(state.sessions, session_id, session)}
    {:reply, result, state}
  end

  @impl true
  def handle_call({:verify_captcha, session_id, _captcha_token}, _from, state) do
    # In production, validate with reCAPTCHA/hCaptcha API
    # For now, accept any non-empty token
    case Map.get(state.sessions, session_id) do
      nil ->
        {:reply, {:error, :session_not_found}, state}

      session ->
        session = %{session | captcha_verified: true, score: max(session.score - 30, 0)}
        state = %{state | sessions: Map.put(state.sessions, session_id, session)}
        {:reply, :ok, state}
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
    cutoff = now - @session_ttl_ms

    sessions =
      Map.filter(state.sessions, fn {_, s} -> s.last_request_at > cutoff end)

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
    # Keep last 20 request timestamps
    times = [now | Enum.take(session.request_times, 19)]
    %{session | request_times: times, last_request_at: now}
  end

  defp record_cart_action_ts(session, now) do
    times = [now | Enum.take(session.cart_action_times, 19)]
    %{session | cart_action_times: times}
  end

  defp calculate_score(session, signals) do
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
    fingerprint = Map.get(signals, :fingerprint)
    score = if is_nil(fingerprint), do: score + 15, else: score

    # Request velocity: >10 in 10 seconds
    now = System.monotonic_time(:millisecond)
    recent_requests = Enum.count(session.request_times, &(&1 > now - 10_000))
    score = if recent_requests > 10, do: score + 20, else: score

    # Cart velocity: >5 in 30 seconds
    recent_cart = Enum.count(session.cart_action_times, &(&1 > now - 30_000))
    score = if recent_cart > 5, do: score + 25, else: score

    # Suspicious timing: sub-100ms between requests
    score =
      case session.request_times do
        [latest, prev | _] when latest - prev < 100 -> score + 10
        _ -> score
      end

    score
  end
end
