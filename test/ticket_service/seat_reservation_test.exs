defmodule TicketService.SeatReservationTest do
  use TicketService.DataCase

  alias TicketService.Carts
  alias TicketService.Seating
  alias TicketService.Seating.Seat
  alias TicketService.Venues
  alias TicketService.Events
  alias TicketService.Tickets

  setup do
    {:ok, venue} = Venues.create_venue(%{name: "Concert Hall", capacity: 500})

    {:ok, event} =
      Events.create_event(%{
        title: "Rock Show",
        venue_id: venue.id,
        starts_at: DateTime.utc_now() |> DateTime.add(86400)
      })

    {:ok, section} =
      Seating.create_section(%{
        name: "Orchestra",
        type: "reserved",
        capacity: 20,
        row_count: 2,
        seats_per_row: 10,
        venue_id: venue.id
      })

    {:ok, ticket_type} =
      Tickets.create_ticket_type(%{
        name: "Reserved Seat",
        price: 75.00,
        quantity: 20,
        event_id: event.id
      })

    seats = Seating.list_seats(section.id)

    %{
      venue: venue,
      event: event,
      section: section,
      ticket_type: ticket_type,
      seats: seats
    }
  end

  describe "atomic seat hold with optimistic locking" do
    test "holds multiple seats atomically (all-or-nothing)", %{ticket_type: tt, seats: seats} do
      [s1, s2, s3 | _] = seats
      seat_ids = [s1.id, s2.id, s3.id]
      session_id = UUID.uuid4()

      {:ok, _} = Carts.get_or_create_cart(session_id)
      {:ok, cart} = Carts.add_item(session_id, tt.id, 3, seat_ids: seat_ids)
      assert cart.total_tickets == 3

      # All seats should be held
      for id <- seat_ids do
        seat = Repo.get!(Seat, id)
        assert seat.status == "held"
      end
    end

    test "rejects hold when any seat is already held", %{ticket_type: tt, seats: seats} do
      [s1, s2 | _] = seats

      # Session A holds seat 1
      session_a = UUID.uuid4()
      {:ok, _} = Carts.get_or_create_cart(session_a)
      {:ok, _} = Carts.add_item(session_a, tt.id, 1, seat_ids: [s1.id])

      # Session B tries to hold seats 1 and 2 — should fail because seat 1 is held
      session_b = UUID.uuid4()
      {:ok, _} = Carts.get_or_create_cart(session_b)
      assert {:error, :seat_conflict} = Carts.add_item(session_b, tt.id, 2, seat_ids: [s1.id, s2.id])

      # Seat 2 should still be available (all-or-nothing)
      assert Repo.get!(Seat, s2.id).status == "available"
    end

    test "seat hold increments lock_version", %{ticket_type: tt, seats: seats} do
      [s1 | _] = seats
      session_id = UUID.uuid4()

      original = Repo.get!(Seat, s1.id)
      assert original.lock_version == 1

      {:ok, _} = Carts.get_or_create_cart(session_id)
      {:ok, _} = Carts.add_item(session_id, tt.id, 1, seat_ids: [s1.id])

      updated = Repo.get!(Seat, s1.id)
      assert updated.lock_version == 2
      assert updated.status == "held"
    end

    test "releasing seats restores availability", %{ticket_type: tt, seats: seats} do
      [s1, s2 | _] = seats
      seat_ids = [s1.id, s2.id]
      session_id = UUID.uuid4()

      {:ok, _} = Carts.get_or_create_cart(session_id)
      {:ok, _} = Carts.add_item(session_id, tt.id, 2, seat_ids: seat_ids)
      {:ok, _} = Carts.remove_item(session_id, tt.id)

      for id <- seat_ids do
        seat = Repo.get!(Seat, id)
        assert seat.status == "available"
      end
    end

    test "cart TTL expiry releases held seats", %{ticket_type: tt, seats: seats} do
      [s1 | _] = seats
      session_id = UUID.uuid4()

      {:ok, _} = Carts.get_or_create_cart(session_id, ttl_ms: 50)
      {:ok, _} = Carts.add_item(session_id, tt.id, 1, seat_ids: [s1.id])

      assert Repo.get!(Seat, s1.id).status == "held"

      # Wait for TTL expiry
      Process.sleep(100)

      assert Repo.get!(Seat, s1.id).status == "available"
    end

    test "rejects hold for non-existent seat IDs", %{ticket_type: tt} do
      fake_id = UUID.uuid4()
      session_id = UUID.uuid4()

      {:ok, _} = Carts.get_or_create_cart(session_id)
      assert {:error, :seats_not_found} = Carts.add_item(session_id, tt.id, 1, seat_ids: [fake_id])
    end
  end

  describe "concurrent seat selection" do
    test "two sessions competing for the same seat — one succeeds, one gets conflict",
         %{ticket_type: tt, seats: seats} do
      [target_seat | _] = seats

      session_a = UUID.uuid4()
      session_b = UUID.uuid4()

      {:ok, _} = Carts.get_or_create_cart(session_a)
      {:ok, _} = Carts.get_or_create_cart(session_b)

      # Run concurrently
      task_a =
        Task.async(fn ->
          Carts.add_item(session_a, tt.id, 1, seat_ids: [target_seat.id])
        end)

      task_b =
        Task.async(fn ->
          Carts.add_item(session_b, tt.id, 1, seat_ids: [target_seat.id])
        end)

      result_a = Task.await(task_a)
      result_b = Task.await(task_b)

      results = [result_a, result_b]

      # Exactly one should succeed, one should fail
      successes = Enum.count(results, &match?({:ok, _}, &1))
      failures = Enum.count(results, &match?({:error, _}, &1))

      assert successes == 1, "Expected exactly one success, got #{successes}: #{inspect(results)}"
      assert failures == 1, "Expected exactly one failure, got #{failures}: #{inspect(results)}"

      # The failure should be a conflict error
      [{:error, reason}] = Enum.filter(results, &match?({:error, _}, &1))
      assert reason in [:seat_conflict, :seats_unavailable]

      # The seat should be held (not double-held)
      final_seat = Repo.get!(Seat, target_seat.id)
      assert final_seat.status == "held"
    end

    test "two sessions competing for overlapping seat sets — one succeeds, one gets conflict",
         %{ticket_type: tt, seats: seats} do
      [s1, s2, s3 | _] = seats

      session_a = UUID.uuid4()
      session_b = UUID.uuid4()

      {:ok, _} = Carts.get_or_create_cart(session_a)
      {:ok, _} = Carts.get_or_create_cart(session_b)

      # Session A wants seats 1,2 — Session B wants seats 2,3 (overlap on seat 2)
      task_a =
        Task.async(fn ->
          Carts.add_item(session_a, tt.id, 2, seat_ids: [s1.id, s2.id])
        end)

      task_b =
        Task.async(fn ->
          Carts.add_item(session_b, tt.id, 2, seat_ids: [s2.id, s3.id])
        end)

      result_a = Task.await(task_a)
      result_b = Task.await(task_b)

      results = [result_a, result_b]
      successes = Enum.count(results, &match?({:ok, _}, &1))
      failures = Enum.count(results, &match?({:error, _}, &1))

      assert successes == 1
      assert failures == 1

      # The contested seat should be held exactly once
      assert Repo.get!(Seat, s2.id).status == "held"
    end
  end
end
