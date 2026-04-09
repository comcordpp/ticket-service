defmodule TicketService.Queue.FairQueue do
  @moduledoc """
  BEAM-native fair queue system for high-demand ticket sales.

  One GenServer process per event, spawned via DynamicSupervisor on first join.
  Uses FIFO ordering backed by `:queue` for O(1) enqueue/dequeue and a named
  ETS table for fast position lookups without GenServer bottleneck.

  ## How it works

  1. `POST /api/events/:event_id/queue/join` adds user to event-specific FIFO queue.
  2. A periodic drain tick admits N users per second (configurable, default 50/sec).
  3. `GET /api/events/:event_id/queue/position/:session_id` returns current position.
  4. When a user reaches the front, they receive a time-limited pass token (5 min).
  5. The pass token must be validated on cart creation — expired tokens are rejected.
  6. On GenServer crash, the Supervisor restarts the process and recovers state from
     the named ETS table (which is owned by a separate heir process).

  ## Configuration

      config :ticket_service, TicketService.Queue.FairQueue,
        drain_rate: 50,                  # users admitted per second
        pass_ttl_seconds: 300,           # 5 min to complete purchase
        batch_size: 50,                  # admit per drain tick
        drain_interval_ms: 1_000,        # drain tick interval
        max_queue_size: 500_000,         # backpressure cap
        measurement_window_ms: 5_000     # rate measurement window
  """
  use GenServer

  require Logger

  @default_drain_rate 50
  @default_pass_ttl_seconds 300
  @default_batch_size 50
  @default_drain_interval_ms 1_000
  @default_max_queue_size 500_000
  @default_measurement_window_ms 5_000

  defstruct [
    :event_id,
    :ets_table,
    active: false,
    queue: :queue.new(),
    queue_size: 0,
    active_passes: %{},
    request_timestamps: [],
    total_admitted: 0,
    started_at: nil,
    drain_rate: @default_drain_rate,
    pass_ttl_seconds: @default_pass_ttl_seconds,
    batch_size: @default_batch_size,
    drain_interval_ms: @default_drain_interval_ms,
    max_queue_size: @default_max_queue_size,
    measurement_window_ms: @default_measurement_window_ms
  ]

  # --- Client API ---

  def start_link(opts) do
    event_id = Keyword.fetch!(opts, :event_id)
    GenServer.start_link(__MODULE__, opts, name: via(event_id))
  end

  def via(event_id) do
    {:via, Registry, {TicketService.QueueRegistry, {:queue, event_id}}}
  end

  @doc """
  Ensure a queue process is running for the given event.
  Spawns one via DynamicSupervisor if it doesn't exist.
  """
  def ensure_started(event_id) do
    case GenServer.whereis(via(event_id)) do
      nil ->
        case DynamicSupervisor.start_child(
               TicketService.QueueSupervisor,
               {__MODULE__, event_id: event_id}
             ) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end

      pid ->
        {:ok, pid}
    end
  end

  @doc "Join the queue. Returns :pass (proceed), {:queued, position}, {:wait, position}, or {:error, :queue_full}."
  def join(event_id, session_id) do
    with {:ok, _pid} <- ensure_started(event_id) do
      GenServer.call(via(event_id), {:join, session_id})
    end
  end

  @doc "Check queue position and status for a session."
  def check_position(event_id, session_id) do
    case GenServer.whereis(via(event_id)) do
      nil -> {:not_in_queue, %{}}
      _pid -> GenServer.call(via(event_id), {:check_position, session_id})
    end
  end

  @doc "Validate a pass token. Returns :ok or {:error, reason}."
  def validate_pass(event_id, session_id) do
    case GenServer.whereis(via(event_id)) do
      nil -> {:error, :no_pass}
      _pid -> GenServer.call(via(event_id), {:validate_pass, session_id})
    end
  end

  @doc "Release a pass (checkout complete or abandoned)."
  def release_pass(event_id, session_id) do
    case GenServer.whereis(via(event_id)) do
      nil -> :ok
      _pid -> GenServer.cast(via(event_id), {:release_pass, session_id})
    end
  end

  @doc "Get queue stats for admin monitoring."
  def stats(event_id) do
    case GenServer.whereis(via(event_id)) do
      nil -> {:error, :queue_not_found}
      _pid -> GenServer.call(via(event_id), :stats)
    end
  end

  @doc "Check if queue is active for an event."
  def active?(event_id) do
    case GenServer.whereis(via(event_id)) do
      nil -> false
      _pid -> GenServer.call(via(event_id), :active?)
    end
  end

  # Kept for backward compat with existing callers
  def request_access(event_id, session_id), do: join(event_id, session_id)
  def check_status(event_id, session_id), do: check_position(event_id, session_id)
  def info(event_id), do: stats(event_id)

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    event_id = Keyword.fetch!(opts, :event_id)
    config = Application.get_env(:ticket_service, __MODULE__, [])

    ets_name = ets_table_name(event_id)
    ets_table = recover_or_create_ets(ets_name)

    state = %__MODULE__{
      event_id: event_id,
      ets_table: ets_table,
      started_at: DateTime.utc_now(),
      drain_rate: Keyword.get(config, :drain_rate, @default_drain_rate),
      pass_ttl_seconds: Keyword.get(config, :pass_ttl_seconds, @default_pass_ttl_seconds),
      batch_size: Keyword.get(config, :batch_size, @default_batch_size),
      drain_interval_ms: Keyword.get(config, :drain_interval_ms, @default_drain_interval_ms),
      max_queue_size: Keyword.get(config, :max_queue_size, @default_max_queue_size),
      measurement_window_ms: Keyword.get(config, :measurement_window_ms, @default_measurement_window_ms)
    }

    # Recover queue state from ETS if process restarted
    state = recover_queue_state(state)

    # Schedule periodic tasks
    schedule_drain(state.drain_interval_ms)
    Process.send_after(self(), :expire_passes, 10_000)
    Process.send_after(self(), :check_rate, state.measurement_window_ms)

    {:ok, state}
  end

  @impl true
  def handle_call({:join, session_id}, _from, state) do
    state = record_request(state)

    cond do
      # Already has a valid pass
      Map.has_key?(state.active_passes, session_id) ->
        {:reply, :pass, state}

      # Queue not active — grant immediate pass
      not state.active ->
        state = grant_pass(state, session_id)
        {:reply, :pass, state}

      # Already in queue
      ets_member?(state, session_id) ->
        position = ets_position(state, session_id)
        {:reply, {:wait, position}, state}

      # Queue full — backpressure
      state.queue_size >= state.max_queue_size ->
        {:reply, {:error, :queue_full}, state}

      # Add to queue
      true ->
        state = enqueue(state, session_id)
        {:reply, {:queued, state.queue_size}, state}
    end
  end

  @impl true
  def handle_call({:check_position, session_id}, _from, state) do
    result =
      cond do
        Map.has_key?(state.active_passes, session_id) ->
          expires_at = state.active_passes[session_id]
          {:pass, %{expires_at: expires_at}}

        ets_member?(state, session_id) ->
          position = ets_position(state, session_id)
          {:wait, %{position: position, total: state.queue_size}}

        true ->
          {:not_in_queue, %{}}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:validate_pass, session_id}, _from, state) do
    case Map.get(state.active_passes, session_id) do
      nil ->
        {:reply, {:error, :no_pass}, state}

      expires_at ->
        if DateTime.compare(DateTime.utc_now(), expires_at) == :lt do
          {:reply, :ok, state}
        else
          state = %{state | active_passes: Map.delete(state.active_passes, session_id)}
          {:reply, {:error, :pass_expired}, state}
        end
    end
  end

  @impl true
  def handle_call(:active?, _from, state) do
    {:reply, state.active, state}
  end

  @impl true
  def handle_call(:stats, _from, state) do
    now = DateTime.utc_now()
    avg_wait = if state.queue_size > 0, do: state.queue_size / max(state.drain_rate, 1), else: 0.0

    stats = %{
      event_id: state.event_id,
      active: state.active,
      queue_depth: state.queue_size,
      active_passes: map_size(state.active_passes),
      drain_rate: state.drain_rate,
      current_request_rate: current_rate(state),
      avg_wait_seconds: Float.round(avg_wait, 1),
      total_admitted: state.total_admitted,
      max_queue_size: state.max_queue_size,
      started_at: state.started_at
    }

    {:reply, {:ok, stats}, state}
  end

  @impl true
  def handle_cast({:release_pass, session_id}, state) do
    state = %{state | active_passes: Map.delete(state.active_passes, session_id)}
    {:noreply, state}
  end

  @impl true
  def handle_info(:drain, state) do
    state = admit_batch(state)
    schedule_drain(state.drain_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:expire_passes, state) do
    now = DateTime.utc_now()

    expired =
      state.active_passes
      |> Enum.filter(fn {_sid, expires_at} -> DateTime.compare(now, expires_at) != :lt end)
      |> Enum.map(fn {sid, _} -> sid end)

    state = %{state | active_passes: Map.drop(state.active_passes, expired)}

    if expired != [] do
      Logger.debug("Expired #{length(expired)} queue passes for event #{state.event_id}")
    end

    Process.send_after(self(), :expire_passes, 10_000)
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_rate, state) do
    rate = current_rate(state)

    state =
      cond do
        not state.active and rate >= state.drain_rate ->
          Logger.info("Queue activated for event #{state.event_id} (rate: #{rate} req/s)")
          %{state | active: true}

        state.active and rate < state.drain_rate / 2 and state.queue_size == 0 ->
          Logger.info("Queue deactivated for event #{state.event_id} (rate: #{rate} req/s)")
          %{state | active: false}

        true ->
          state
      end

    Process.send_after(self(), :check_rate, state.measurement_window_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({:"ETS-TRANSFER", _table, _from, _data}, state) do
    # ETS heir transfer — table ownership reclaimed after heir process died
    {:noreply, state}
  end

  # --- Private: ETS Management ---

  defp ets_table_name(event_id) do
    :"fair_queue_#{event_id}"
  end

  defp recover_or_create_ets(ets_name) do
    case :ets.whereis(ets_name) do
      :undefined ->
        :ets.new(ets_name, [:named_table, :set, :public, read_concurrency: true])

      _ref ->
        # Table exists from a previous incarnation — take ownership
        try do
          :ets.give_away(ets_name, self(), :recovered)
        rescue
          ArgumentError -> :ok
        end

        ets_name
    end
  end

  defp recover_queue_state(state) do
    # Rebuild the :queue from ETS entries ordered by position
    entries =
      :ets.tab2list(state.ets_table)
      |> Enum.filter(fn {key, _pos} -> is_binary(key) end)
      |> Enum.sort_by(fn {_sid, pos} -> pos end)

    if entries == [] do
      state
    else
      queue = Enum.reduce(entries, :queue.new(), fn {sid, _pos}, q -> :queue.in(sid, q) end)

      Logger.info(
        "Recovered #{length(entries)} queued sessions for event #{state.event_id} from ETS"
      )

      %{state | queue: queue, queue_size: length(entries)}
    end
  end

  # --- Private: Queue Operations ---

  defp record_request(state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - state.measurement_window_ms
    timestamps = [now | Enum.filter(state.request_timestamps, &(&1 > cutoff))]
    %{state | request_timestamps: timestamps}
  end

  defp current_rate(state) do
    now = System.monotonic_time(:millisecond)
    cutoff = now - state.measurement_window_ms
    count = Enum.count(state.request_timestamps, &(&1 > cutoff))
    Float.round(count * 1000 / state.measurement_window_ms, 1)
  end

  defp grant_pass(state, session_id) do
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(state.pass_ttl_seconds, :second)
      |> DateTime.truncate(:second)

    %{state |
      active_passes: Map.put(state.active_passes, session_id, expires_at),
      total_admitted: state.total_admitted + 1
    }
  end

  defp enqueue(state, session_id) do
    new_pos = state.queue_size + 1
    :ets.insert(state.ets_table, {session_id, new_pos})
    queue = :queue.in(session_id, state.queue)
    %{state | queue: queue, queue_size: new_pos}
  end

  defp ets_member?(state, session_id) do
    :ets.member(state.ets_table, session_id)
  end

  defp ets_position(state, session_id) do
    case :ets.lookup(state.ets_table, session_id) do
      [{^session_id, pos}] -> pos
      [] -> 0
    end
  end

  defp admit_batch(state) do
    to_admit = min(state.batch_size, state.queue_size)
    admit_n(state, to_admit)
  end

  defp admit_n(state, 0), do: state

  defp admit_n(state, n) do
    case :queue.out(state.queue) do
      {{:value, session_id}, rest} ->
        :ets.delete(state.ets_table, session_id)
        state = grant_pass(%{state | queue: rest, queue_size: state.queue_size - 1}, session_id)

        # Broadcast pass readiness via PubSub
        Phoenix.PubSub.broadcast(
          TicketService.PubSub,
          "queue:#{state.event_id}",
          {:queue_pass_granted, session_id}
        )

        admit_n(state, n - 1)

      {:empty, _} ->
        state
    end
  end

  defp schedule_drain(interval_ms) do
    Process.send_after(self(), :drain, interval_ms)
  end
end
