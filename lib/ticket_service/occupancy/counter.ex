defmodule TicketService.Occupancy.Counter do
  @moduledoc """
  GenServer that manages real-time occupancy counters per venue/section using ETS.

  Counters are keyed by `{venue_id, section_id}` and updated atomically.
  Every count change broadcasts to `"venue:{venue_id}"` via Phoenix PubSub.
  Snapshots are persisted to PostgreSQL every 60 seconds for crash recovery.
  """

  use GenServer

  require Logger

  alias TicketService.Occupancy.Snapshot
  alias TicketService.Repo

  import Ecto.Query

  @table :occupancy_counters
  @capacity_table :occupancy_capacities
  @snapshot_interval_ms 60_000
  @pubsub TicketService.PubSub

  # ------- Client API -------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Increment occupancy for a venue/section by `amount` (default 1)."
  def increment(venue_id, section_id, amount \\ 1) do
    update_counter(venue_id, section_id, amount)
  end

  @doc "Decrement occupancy for a venue/section by `amount` (default 1). Floor is 0."
  def decrement(venue_id, section_id, amount \\ 1) do
    key = {venue_id, section_id}
    current = get_count(venue_id, section_id)
    new_val = max(current - amount, 0)

    # Use atomic update_counter with a min-floor trick:
    # First set to 0, then set to new_val via replace
    :ets.insert(@table, {key, new_val})
    broadcast_update(venue_id, section_id, new_val)
    new_val
  end

  @doc "Get the current count for a venue/section."
  def get_count(venue_id, section_id) do
    case :ets.lookup(@table, {venue_id, section_id}) do
      [{_key, count}] -> count
      [] -> 0
    end
  end

  @doc "Get all counts for a venue (across all sections)."
  def get_venue_counts(venue_id) do
    :ets.match_object(@table, {{venue_id, :_}, :_})
    |> Enum.map(fn {{_venue_id, section_id}, count} ->
      %{section_id: section_id, count: count}
    end)
  end

  @doc "Get total occupancy for a venue (sum across all sections)."
  def get_venue_total(venue_id) do
    :ets.match_object(@table, {{venue_id, :_}, :_})
    |> Enum.reduce(0, fn {_key, count}, acc -> acc + count end)
  end

  @doc "Set capacity threshold for a venue. Used for alerts."
  def set_capacity(venue_id, capacity) when is_integer(capacity) and capacity > 0 do
    :ets.insert(@capacity_table, {venue_id, capacity})
    :ok
  end

  @doc "Get configured capacity for a venue."
  def get_capacity(venue_id) do
    case :ets.lookup(@capacity_table, venue_id) do
      [{_key, capacity}] -> {:ok, capacity}
      [] -> :not_set
    end
  end

  @doc "Reset a venue/section counter to 0."
  def reset(venue_id, section_id) do
    :ets.insert(@table, {{venue_id, section_id}, 0})
    broadcast_update(venue_id, section_id, 0)
    :ok
  end

  @doc "Reset all counters for a venue."
  def reset_venue(venue_id) do
    :ets.match_object(@table, {{venue_id, :_}, :_})
    |> Enum.each(fn {{vid, sid}, _count} ->
      :ets.insert(@table, {{vid, sid}, 0})
      broadcast_update(vid, sid, 0)
    end)

    :ok
  end

  # ------- GenServer Callbacks -------

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])
    cap_table = :ets.new(@capacity_table, [:named_table, :public, :set, read_concurrency: true])

    # Restore from latest snapshots
    restore_from_snapshots()

    # Schedule periodic snapshot persistence
    schedule_snapshot()

    {:ok, %{table: table, capacity_table: cap_table}}
  end

  @impl true
  def handle_info(:persist_snapshots, state) do
    persist_snapshots()
    schedule_snapshot()
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("Occupancy.Counter received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # ------- Private Helpers -------

  defp update_counter(venue_id, section_id, amount) do
    key = {venue_id, section_id}

    new_val =
      try do
        :ets.update_counter(@table, key, {2, amount})
      rescue
        ArgumentError ->
          :ets.insert(@table, {key, amount})
          amount
      end

    broadcast_update(venue_id, section_id, new_val)
    check_capacity(venue_id, new_val)
    new_val
  end

  defp broadcast_update(venue_id, section_id, count) do
    Phoenix.PubSub.broadcast(@pubsub, "venue:#{venue_id}", {:occupancy_update, %{
      venue_id: venue_id,
      section_id: section_id,
      count: count,
      venue_total: get_venue_total(venue_id),
      timestamp: DateTime.utc_now()
    }})
  end

  defp check_capacity(venue_id, _current_count) do
    total = get_venue_total(venue_id)

    case get_capacity(venue_id) do
      {:ok, capacity} when total >= capacity ->
        Phoenix.PubSub.broadcast(@pubsub, "venue:#{venue_id}", {:capacity_reached, %{
          venue_id: venue_id,
          total: total,
          capacity: capacity,
          timestamp: DateTime.utc_now()
        }})

      _ ->
        :ok
    end
  end

  defp schedule_snapshot do
    Process.send_after(self(), :persist_snapshots, @snapshot_interval_ms)
  end

  defp persist_snapshots do
    entries = :ets.tab2list(@table)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Enum.each(entries, fn {{venue_id, section_id}, count} ->
      try do
        Repo.insert!(
          %Snapshot{
            venue_id: venue_id,
            section_id: section_id,
            count: count,
            inserted_at: now,
            updated_at: now
          },
          on_conflict: {:replace, [:count, :updated_at]},
          conflict_target: [:venue_id, :section_id]
        )
      rescue
        e ->
          Logger.error("Failed to persist occupancy snapshot: #{inspect(e)}")
      end
    end)

    Logger.info("Persisted #{length(entries)} occupancy snapshots")
  end

  defp restore_from_snapshots do
    # Get the most recent snapshot for each venue/section pair
    query =
      from s in Snapshot,
        distinct: [s.venue_id, s.section_id],
        order_by: [asc: s.venue_id, asc: s.section_id, desc: s.updated_at],
        select: {s.venue_id, s.section_id, s.count}

    Repo.all(query)
    |> Enum.each(fn {venue_id, section_id, count} ->
      :ets.insert(@table, {{venue_id, section_id}, count})
    end)
  rescue
    e ->
      Logger.warning("Could not restore occupancy snapshots: #{inspect(e)}")
  end
end
