defmodule TicketService.Occupancy.CounterTest do
  use TicketService.DataCase, async: false

  alias TicketService.Occupancy.Counter

  @venue_id "00000000-0000-0000-0000-000000000001"
  @section_a "00000000-0000-0000-0000-00000000000a"
  @section_b "00000000-0000-0000-0000-00000000000b"

  setup do
    # Clean ETS tables between tests
    :ets.delete_all_objects(:occupancy_counters)
    :ets.delete_all_objects(:occupancy_capacities)
    :ok
  end

  describe "increment/3" do
    test "increments counter by 1 by default" do
      assert Counter.increment(@venue_id, @section_a) == 1
      assert Counter.get_count(@venue_id, @section_a) == 1
    end

    test "increments by a custom amount" do
      assert Counter.increment(@venue_id, @section_a, 5) == 5
      assert Counter.get_count(@venue_id, @section_a) == 5
    end

    test "accumulates increments" do
      Counter.increment(@venue_id, @section_a, 3)
      Counter.increment(@venue_id, @section_a, 2)
      assert Counter.get_count(@venue_id, @section_a) == 5
    end
  end

  describe "decrement/3" do
    test "decrements counter by 1" do
      Counter.increment(@venue_id, @section_a, 10)
      assert Counter.decrement(@venue_id, @section_a) == 9
    end

    test "floors at 0" do
      Counter.increment(@venue_id, @section_a, 2)
      Counter.decrement(@venue_id, @section_a, 5)
      assert Counter.get_count(@venue_id, @section_a) == 0
    end

    test "decrement on uninitialized counter returns 0" do
      assert Counter.decrement(@venue_id, @section_a) == 0
    end
  end

  describe "get_count/2" do
    test "returns 0 for uninitialized counter" do
      assert Counter.get_count(@venue_id, @section_a) == 0
    end

    test "returns current count" do
      Counter.increment(@venue_id, @section_a, 7)
      assert Counter.get_count(@venue_id, @section_a) == 7
    end
  end

  describe "get_venue_counts/1" do
    test "returns all sections for a venue" do
      Counter.increment(@venue_id, @section_a, 10)
      Counter.increment(@venue_id, @section_b, 20)

      counts = Counter.get_venue_counts(@venue_id)
      assert length(counts) == 2
      assert Enum.find(counts, &(&1.section_id == @section_a)).count == 10
      assert Enum.find(counts, &(&1.section_id == @section_b)).count == 20
    end

    test "returns empty list for unknown venue" do
      assert Counter.get_venue_counts("unknown-venue") == []
    end
  end

  describe "get_venue_total/1" do
    test "sums across all sections" do
      Counter.increment(@venue_id, @section_a, 10)
      Counter.increment(@venue_id, @section_b, 20)
      assert Counter.get_venue_total(@venue_id) == 30
    end

    test "returns 0 for unknown venue" do
      assert Counter.get_venue_total("unknown-venue") == 0
    end
  end

  describe "capacity management" do
    test "set and get capacity" do
      Counter.set_capacity(@venue_id, 50_000)
      assert Counter.get_capacity(@venue_id) == {:ok, 50_000}
    end

    test "returns :not_set for unknown venue" do
      assert Counter.get_capacity("unknown") == :not_set
    end
  end

  describe "reset/2" do
    test "resets a section counter to 0" do
      Counter.increment(@venue_id, @section_a, 100)
      Counter.reset(@venue_id, @section_a)
      assert Counter.get_count(@venue_id, @section_a) == 0
    end
  end

  describe "reset_venue/1" do
    test "resets all section counters for a venue" do
      Counter.increment(@venue_id, @section_a, 10)
      Counter.increment(@venue_id, @section_b, 20)
      Counter.reset_venue(@venue_id)
      assert Counter.get_venue_total(@venue_id) == 0
    end
  end

  describe "PubSub broadcasts" do
    test "broadcasts on increment" do
      Phoenix.PubSub.subscribe(TicketService.PubSub, "venue:#{@venue_id}")
      Counter.increment(@venue_id, @section_a)

      assert_receive {:occupancy_update, %{
        venue_id: @venue_id,
        section_id: @section_a,
        count: 1
      }}
    end

    test "broadcasts on decrement" do
      Counter.increment(@venue_id, @section_a, 5)
      Phoenix.PubSub.subscribe(TicketService.PubSub, "venue:#{@venue_id}")
      Counter.decrement(@venue_id, @section_a)

      assert_receive {:occupancy_update, %{
        venue_id: @venue_id,
        section_id: @section_a,
        count: 4
      }}
    end

    test "broadcasts capacity_reached when threshold hit" do
      Counter.set_capacity(@venue_id, 10)
      Phoenix.PubSub.subscribe(TicketService.PubSub, "venue:#{@venue_id}")
      Counter.increment(@venue_id, @section_a, 10)

      assert_receive {:capacity_reached, %{
        venue_id: @venue_id,
        total: 10,
        capacity: 10
      }}
    end
  end
end
