defmodule TicketService.CartsTest do
  use TicketService.DataCase

  alias TicketService.Carts
  alias TicketService.Carts.CartServer
  alias TicketService.Venues
  alias TicketService.Events
  alias TicketService.Tickets
  alias TicketService.Seating

  setup do
    {:ok, venue} = Venues.create_venue(%{name: "Test Arena", capacity: 1000})
    {:ok, event} = Events.create_event(%{
      title: "Test Concert",
      venue_id: venue.id,
      starts_at: DateTime.utc_now() |> DateTime.add(86400)
    })
    {:ok, ticket_type} = Tickets.create_ticket_type(%{
      name: "General Admission",
      price: 50.00,
      quantity: 100,
      event_id: event.id
    })

    session_id = UUID.uuid4()

    %{venue: venue, event: event, ticket_type: ticket_type, session_id: session_id}
  end

  describe "get_or_create_cart/2" do
    test "creates a new cart for a session", %{session_id: session_id} do
      assert {:ok, cart} = Carts.get_or_create_cart(session_id)
      assert cart.session_id == session_id
      assert cart.items == []
      assert cart.item_count == 0
      assert cart.total_tickets == 0
    end

    test "returns existing cart on subsequent calls", %{session_id: session_id} do
      {:ok, cart1} = Carts.get_or_create_cart(session_id)
      {:ok, cart2} = Carts.get_or_create_cart(session_id)
      assert cart1.session_id == cart2.session_id
    end

    test "different sessions get different carts" do
      session_a = UUID.uuid4()
      session_b = UUID.uuid4()
      {:ok, cart_a} = Carts.get_or_create_cart(session_a)
      {:ok, cart_b} = Carts.get_or_create_cart(session_b)
      assert cart_a.session_id != cart_b.session_id
    end
  end

  describe "add_item/4" do
    test "adds a ticket type to the cart", %{session_id: session_id, ticket_type: tt} do
      {:ok, _} = Carts.get_or_create_cart(session_id)
      assert {:ok, cart} = Carts.add_item(session_id, tt.id, 2)
      assert cart.total_tickets == 2
      assert length(cart.items) == 1

      [item] = cart.items
      assert item.ticket_type_id == tt.id
      assert item.quantity == 2
    end

    test "increments quantity for duplicate adds", %{session_id: session_id, ticket_type: tt} do
      {:ok, _} = Carts.get_or_create_cart(session_id)
      {:ok, _} = Carts.add_item(session_id, tt.id, 2)
      {:ok, cart} = Carts.add_item(session_id, tt.id, 3)
      assert cart.total_tickets == 5
    end

    test "holds inventory (increments sold_count)", %{session_id: session_id, ticket_type: tt} do
      {:ok, _} = Carts.get_or_create_cart(session_id)
      {:ok, _} = Carts.add_item(session_id, tt.id, 5)

      updated_tt = Tickets.get_ticket_type!(tt.id)
      assert updated_tt.sold_count == 5
    end

    test "rejects when insufficient inventory", %{session_id: session_id, ticket_type: tt} do
      {:ok, _} = Carts.get_or_create_cart(session_id)
      assert {:error, :insufficient_inventory} = Carts.add_item(session_id, tt.id, 101)
    end

    test "returns error when cart does not exist", %{ticket_type: tt} do
      assert {:error, :cart_not_found} = Carts.add_item("nonexistent", tt.id, 1)
    end
  end

  describe "remove_item/2" do
    test "removes item and releases inventory", %{session_id: session_id, ticket_type: tt} do
      {:ok, _} = Carts.get_or_create_cart(session_id)
      {:ok, _} = Carts.add_item(session_id, tt.id, 3)
      assert {:ok, cart} = Carts.remove_item(session_id, tt.id)
      assert cart.items == []
      assert cart.total_tickets == 0

      updated_tt = Tickets.get_ticket_type!(tt.id)
      assert updated_tt.sold_count == 0
    end

    test "returns error for non-existent item", %{session_id: session_id} do
      {:ok, _} = Carts.get_or_create_cart(session_id)
      assert {:error, :item_not_found} = Carts.remove_item(session_id, UUID.uuid4())
    end
  end

  describe "update_quantity/3" do
    test "increases quantity and holds more inventory", %{session_id: session_id, ticket_type: tt} do
      {:ok, _} = Carts.get_or_create_cart(session_id)
      {:ok, _} = Carts.add_item(session_id, tt.id, 2)
      {:ok, cart} = Carts.update_quantity(session_id, tt.id, 5)
      assert cart.total_tickets == 5

      updated_tt = Tickets.get_ticket_type!(tt.id)
      assert updated_tt.sold_count == 5
    end

    test "decreases quantity and releases inventory", %{session_id: session_id, ticket_type: tt} do
      {:ok, _} = Carts.get_or_create_cart(session_id)
      {:ok, _} = Carts.add_item(session_id, tt.id, 5)
      {:ok, cart} = Carts.update_quantity(session_id, tt.id, 2)
      assert cart.total_tickets == 2

      updated_tt = Tickets.get_ticket_type!(tt.id)
      assert updated_tt.sold_count == 2
    end

    test "rejects increase beyond inventory", %{session_id: session_id, ticket_type: tt} do
      {:ok, _} = Carts.get_or_create_cart(session_id)
      {:ok, _} = Carts.add_item(session_id, tt.id, 95)
      assert {:error, :insufficient_inventory} = Carts.update_quantity(session_id, tt.id, 105)

      # Verify original hold is preserved
      updated_tt = Tickets.get_ticket_type!(tt.id)
      assert updated_tt.sold_count == 95
    end
  end

  describe "clear_cart/1" do
    test "clears all items and releases all inventory", %{session_id: session_id, ticket_type: tt} do
      {:ok, _} = Carts.get_or_create_cart(session_id)
      {:ok, _} = Carts.add_item(session_id, tt.id, 5)
      {:ok, cart} = Carts.clear_cart(session_id)
      assert cart.items == []

      updated_tt = Tickets.get_ticket_type!(tt.id)
      assert updated_tt.sold_count == 0
    end
  end

  describe "cart_exists?/1" do
    test "returns false for non-existent cart" do
      refute Carts.cart_exists?("nonexistent-session")
    end

    test "returns true for existing cart", %{session_id: session_id} do
      {:ok, _} = Carts.get_or_create_cart(session_id)
      assert Carts.cart_exists?(session_id)
    end
  end

  describe "TTL expiry" do
    test "cart process stops after TTL", %{session_id: session_id} do
      # Use a very short TTL for testing
      {:ok, _} = Carts.get_or_create_cart(session_id, ttl_ms: 50)
      assert Carts.cart_exists?(session_id)

      # Wait for TTL to fire
      Process.sleep(100)
      refute Carts.cart_exists?(session_id)
    end
  end

  describe "concurrent cart isolation" do
    test "100 concurrent carts are isolated", %{event: event} do
      # Create a separate ticket type per cart to avoid sold_count contention
      sessions =
        for i <- 1..100 do
          {:ok, tt} = Tickets.create_ticket_type(%{
            name: "Type #{i}",
            price: 10.00,
            quantity: 10,
            event_id: event.id
          })

          session_id = UUID.uuid4()
          {:ok, _} = Carts.get_or_create_cart(session_id)
          {session_id, tt.id}
        end

      tasks =
        Enum.map(sessions, fn {session_id, tt_id} ->
          Task.async(fn ->
            {:ok, _} = Carts.add_item(session_id, tt_id, 2)
            {:ok, cart} = Carts.get_cart(session_id)
            assert cart.total_tickets == 2
            assert cart.session_id == session_id
            :ok
          end)
        end)

      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &(&1 == :ok))
    end
  end

  describe "seat holds" do
    setup %{venue: venue, event: event} do
      {:ok, section} = Seating.create_section(%{
        name: "VIP",
        type: "reserved",
        capacity: 10,
        row_count: 2,
        seats_per_row: 5,
        venue_id: venue.id
      })

      {:ok, tt} = Tickets.create_ticket_type(%{
        name: "VIP Reserved",
        price: 100.00,
        quantity: 10,
        event_id: event.id
      })

      seats = Seating.list_seats(section.id)
      %{section: section, vip_tt: tt, seats: seats}
    end

    test "holds specific seats when adding to cart", %{session_id: session_id, vip_tt: tt, seats: seats} do
      [seat1, seat2 | _] = seats
      seat_ids = [seat1.id, seat2.id]

      {:ok, _} = Carts.get_or_create_cart(session_id)
      {:ok, cart} = Carts.add_item(session_id, tt.id, 2, seat_ids: seat_ids)
      assert cart.total_tickets == 2

      # Verify seats are held
      updated_seat1 = Repo.get!(TicketService.Seating.Seat, seat1.id)
      updated_seat2 = Repo.get!(TicketService.Seating.Seat, seat2.id)
      assert updated_seat1.status == "held"
      assert updated_seat2.status == "held"
    end

    test "releases seats when removing from cart", %{session_id: session_id, vip_tt: tt, seats: seats} do
      [seat1, seat2 | _] = seats
      seat_ids = [seat1.id, seat2.id]

      {:ok, _} = Carts.get_or_create_cart(session_id)
      {:ok, _} = Carts.add_item(session_id, tt.id, 2, seat_ids: seat_ids)
      {:ok, _} = Carts.remove_item(session_id, tt.id)

      updated_seat1 = Repo.get!(TicketService.Seating.Seat, seat1.id)
      updated_seat2 = Repo.get!(TicketService.Seating.Seat, seat2.id)
      assert updated_seat1.status == "available"
      assert updated_seat2.status == "available"
    end
  end
end
