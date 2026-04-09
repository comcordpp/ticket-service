defmodule TicketService.Occupancy do
  @moduledoc """
  Public context for venue occupancy tracking.

  Provides entry/exit recording, count queries, and capacity management.
  Delegates to the Counter GenServer for real-time ETS-backed state.
  """

  alias TicketService.Occupancy.Counter

  @doc "Record an entry (increment occupancy) for a venue section."
  def record_entry(venue_id, section_id, count \\ 1) do
    Counter.increment(venue_id, section_id, count)
  end

  @doc "Record an exit (decrement occupancy) for a venue section."
  def record_exit(venue_id, section_id, count \\ 1) do
    Counter.decrement(venue_id, section_id, count)
  end

  @doc "Get current occupancy count for a specific section."
  def get_section_count(venue_id, section_id) do
    Counter.get_count(venue_id, section_id)
  end

  @doc "Get all section counts for a venue."
  def get_venue_breakdown(venue_id) do
    Counter.get_venue_counts(venue_id)
  end

  @doc "Get total occupancy across all sections for a venue."
  def get_venue_total(venue_id) do
    Counter.get_venue_total(venue_id)
  end

  @doc "Set venue capacity threshold for alerts."
  def set_venue_capacity(venue_id, capacity) do
    Counter.set_capacity(venue_id, capacity)
  end

  @doc "Get venue capacity threshold."
  def get_venue_capacity(venue_id) do
    Counter.get_capacity(venue_id)
  end

  @doc "Reset occupancy for a specific section."
  def reset_section(venue_id, section_id) do
    Counter.reset(venue_id, section_id)
  end

  @doc "Reset all occupancy for a venue."
  def reset_venue(venue_id) do
    Counter.reset_venue(venue_id)
  end

  @doc "Subscribe to occupancy updates for a venue."
  def subscribe(venue_id) do
    Phoenix.PubSub.subscribe(TicketService.PubSub, "venue:#{venue_id}")
  end

  @doc "Unsubscribe from occupancy updates for a venue."
  def unsubscribe(venue_id) do
    Phoenix.PubSub.unsubscribe(TicketService.PubSub, "venue:#{venue_id}")
  end
end
