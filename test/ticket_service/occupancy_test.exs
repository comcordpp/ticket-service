defmodule TicketService.OccupancyTest do
  use TicketService.DataCase, async: false

  alias TicketService.Occupancy

  @venue_id "00000000-0000-0000-0000-000000000001"
  @section_id "00000000-0000-0000-0000-00000000000a"

  setup do
    :ets.delete_all_objects(:occupancy_counters)
    :ets.delete_all_objects(:occupancy_capacities)
    :ok
  end

  test "record_entry and record_exit track occupancy" do
    Occupancy.record_entry(@venue_id, @section_id, 5)
    assert Occupancy.get_section_count(@venue_id, @section_id) == 5

    Occupancy.record_exit(@venue_id, @section_id, 2)
    assert Occupancy.get_section_count(@venue_id, @section_id) == 3
  end

  test "get_venue_breakdown returns all sections" do
    Occupancy.record_entry(@venue_id, @section_id, 10)
    breakdown = Occupancy.get_venue_breakdown(@venue_id)
    assert length(breakdown) == 1
    assert hd(breakdown).count == 10
  end

  test "get_venue_total sums sections" do
    Occupancy.record_entry(@venue_id, @section_id, 10)
    assert Occupancy.get_venue_total(@venue_id) == 10
  end

  test "capacity management" do
    assert Occupancy.get_venue_capacity(@venue_id) == :not_set
    Occupancy.set_venue_capacity(@venue_id, 50_000)
    assert Occupancy.get_venue_capacity(@venue_id) == {:ok, 50_000}
  end

  test "subscribe receives updates" do
    Occupancy.subscribe(@venue_id)
    Occupancy.record_entry(@venue_id, @section_id)
    assert_receive {:occupancy_update, %{venue_id: @venue_id, count: 1}}
  end
end
