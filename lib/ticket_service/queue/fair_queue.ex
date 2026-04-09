defmodule TicketService.Queue.FairQueue do
  @moduledoc """
  BEAM-native fair queue system for high-demand ticket sales.

  Automatically activates when request rate exceeds a configurable threshold.
  Uses FIFO ordering backed by ETS for fast lookups and a GenServer for
  coordination. Each session gets exactly one position in the queue.

  ## How it works

  1. When queue is inactive, requests pass through immediately.
  2. When rate exceeds threshold, queue activates — new requests are queued.
  3. Clients poll `/api/queue/status` to check position.
  4. When a client reaches the front, they get a time-limited "pass" token.
  5. The pass token must be presented on checkout to proceed.

  ## Configuration

      config :ticket_service, TicketService.Queue.FairQueue,
        activation_threshold: 100,       # requests/sec to activate queue
        pass_ttl_seconds: 300,           # 5 min to complete purchase
        batch_size: 50,                  # admit 50 at a time
        measurement_window_ms: 5_000     # rate measurement window
  """
  use GenServer

  require Logger

  @default_activation_threshold 100
  @default_pass_ttl_seconds 300
  @default_batch_size 50
  @default_measurement_window_ms 5_000

  defstruct [
    :event_id,
    :ets_table,
    active: false,
    queue: :queue.new(),
    queue_size: 0,
    active_passes: %{},
    request_timestamps: [],
    activation_threshold: @default_activation_threshold,
    pass_ttl_seconds: @default_pass_ttl_seconds,
    batch_size: @default_batch_size,
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

  @doc "Request queue access. Returns :pass (proceed), {:queued, position}, or {:wait, position}."
  def request_access(event_id, session_id) do
    GenServer.call(via(event_id), {:request_access, session_id})
  end

  @doc "Check queue position and status."
  def check_status(event_id, session_id) do
    GenServer.call(via(event_id), {:check_status, session_id})
  end

  @doc "Validate a pass token."
  def validate_pass(event_id, session_id) do
    GenServer.call(via(event_id), {:validate_pass, session_id})
  end

  @doc "Release a pass (checkout complete or abandoned)."
  def release_pass(event_id, session_id) do
    GenServer.cast(via(event_id), {:release_pass, session_id})
  end

  @doc "Get queue info for monitoring."
  def info(event_id) do
    GenServer.call(via(event_id), :info)
  end

  @doc "Check if queue is active for an event."
  def active?(event_id) do
    case GenServer.whereis(via(event_id)) do
      nil -> false
      _pid -> GenServer.call(via(event_id), :active?)
    end
  end

  # --- Server Callbacks ---

  @impl true
  def init(opts) do
    event_id = Keyword.fetch!(opts, :event_id)
    config = Application.get_env(:ticket_service, __MODULE__, [])

    ets_table = :ets.new(:"queue_#{event_id}", [:set, :private])

    state = %__MODULE__{
      event_id: event_id,
      ets_table: ets_table,
      activation_threshold: Keyword.get(config, :activation_threshold, @default_activation_threshold),
      pass_ttl_seconds: Keyword.get(config, :pass_ttl_seconds, @default_pass_ttl_seconds),
      batch_size: Keyword.get(config, :batch_size, @default_batch_size),
      measurement_window_ms: Keyword.get(config, :measurement_window_ms, @default_measurement_window_ms)
    }

    # Schedule periodic pass expiration check
    Process.send_after(self(), :expire_passes, 10_000)
    Process.send_after(self(), :check_rate, state.measurement_window_ms)

    {:ok, state}
  end

  @impl true
  def handle_call({:request_access, session_id}, _from, state) do
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
      in_queue?(state, session_id) ->
        position = queue_position(state, session_id)
        {:reply, {:wait, position}, state}

      # Add to queue
      true ->
        state = enqueue(state, session_id)
        {:reply, {:queued, state.queue_size}, state}
    end
  end

  @impl true
  def handle_call({:check_status, session_id}, _from, state) do
    result =
      cond do
        Map.has_key?(state.active_passes, session_id) ->
          expires_at = state.active_passes[session_id]
          {:pass, %{expires_at: expires_at}}

        in_queue?(state, session_id) ->
          position = queue_position(state, session_id)
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
  def handle_call(:info, _from, state) do
    info = %{
      event_id: state.event_id,
      active: state.active,
      queue_size: state.queue_size,
      active_passes: map_size(state.active_passes),
      current_rate: current_rate(state)
    }

    {:reply, info, state}
  end

  @impl true
  def handle_cast({:release_pass, session_id}, state) do
    state = %{state | active_passes: Map.delete(state.active_passes, session_id)}
    state = admit_batch(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:expire_passes, state) do
    now = DateTime.utc_now()

    expired =
      Enum.filter(state.active_passes, fn {_sid, expires_at} ->
        DateTime.compare(now, expires_at) != :lt
      end)
      |> Enum.map(fn {sid, _} -> sid end)

    state = %{state | active_passes: Map.drop(state.active_passes, expired)}

    if expired != [] do
      Logger.debug("Expired #{length(expired)} queue passes for event #{state.event_id}")
      state = admit_batch(state)
      Process.send_after(self(), :expire_passes, 10_000)
      {:noreply, state}
    else
      Process.send_after(self(), :expire_passes, 10_000)
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:check_rate, state) do
    rate = current_rate(state)

    state =
      cond do
        not state.active and rate >= state.activation_threshold ->
          Logger.info("Queue activated for event #{state.event_id} (rate: #{rate} req/s)")
          %{state | active: true}

        state.active and rate < state.activation_threshold / 2 and state.queue_size == 0 ->
          Logger.info("Queue deactivated for event #{state.event_id} (rate: #{rate} req/s)")
          %{state | active: false}

        true ->
          state
      end

    Process.send_after(self(), :check_rate, state.measurement_window_ms)
    {:noreply, state}
  end

  # --- Private ---

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
    # Convert to requests per second
    Float.round(count * 1000 / state.measurement_window_ms, 1)
  end

  defp grant_pass(state, session_id) do
    expires_at =
      DateTime.utc_now()
      |> DateTime.add(state.pass_ttl_seconds, :second)
      |> DateTime.truncate(:second)

    %{state | active_passes: Map.put(state.active_passes, session_id, expires_at)}
  end

  defp enqueue(state, session_id) do
    :ets.insert(state.ets_table, {session_id, state.queue_size + 1})
    queue = :queue.in(session_id, state.queue)
    %{state | queue: queue, queue_size: state.queue_size + 1}
  end

  defp in_queue?(state, session_id) do
    :ets.member(state.ets_table, session_id)
  end

  defp queue_position(state, session_id) do
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
        admit_n(state, n - 1)

      {:empty, _} ->
        state
    end
  end
end
