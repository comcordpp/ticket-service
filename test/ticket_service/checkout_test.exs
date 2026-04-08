defmodule TicketService.CheckoutTest do
  use TicketService.DataCase

  alias TicketService.Checkout
  alias TicketService.Carts

  setup do
    # Create a venue
    {:ok, venue} =
      TicketService.Venues.create_venue(%{
        name: "Test Arena",
        address: "123 Test St",
        capacity: 1000
      })

    # Create an event
    {:ok, event} =
      TicketService.Events.create_event(%{
        title: "Test Concert",
        description: "A test event",
        category: "concert",
        starts_at: DateTime.add(DateTime.utc_now(), 86400, :second),
        ends_at: DateTime.add(DateTime.utc_now(), 90000, :second),
        venue_id: venue.id
      })

    # Create a ticket type
    {:ok, ticket_type} =
      TicketService.Tickets.create_ticket_type(%{
        name: "General Admission",
        price: Decimal.new("50.00"),
        quantity: 100,
        event_id: event.id
      })

    session_id = "test-session-#{System.unique_integer([:positive])}"

    %{venue: venue, event: event, ticket_type: ticket_type, session_id: session_id}
  end

  describe "get_cart_with_details/1" do
    test "returns enriched cart with fee breakdown", %{
      session_id: session_id,
      ticket_type: ticket_type
    } do
      {:ok, _} = Carts.get_or_create_cart(session_id)
      {:ok, _} = Carts.add_item(session_id, ticket_type.id, 2)

      {:ok, cart} = Checkout.get_cart_with_details(session_id)

      assert cart.session_id == session_id
      assert cart.item_count == 1
      assert cart.total_tickets == 2
      assert length(cart.line_items) == 1

      [item] = cart.line_items
      assert item.ticket_type_id == ticket_type.id
      assert item.ticket_type_name == "General Admission"
      assert item.quantity == 2
      assert item.unit_price == Decimal.new("50.00")

      # Fee breakdown
      assert cart.fees.subtotal == Decimal.new("100.00")
      assert cart.fees.total_tickets == 2
      assert cart.fees.platform_fee == Decimal.new("3.50")
      assert Decimal.gt?(cart.fees.total, cart.fees.subtotal)

      # TTL remaining
      assert cart.ttl_remaining_seconds > 0
    end

    test "returns error for non-existent cart", %{session_id: session_id} do
      assert {:error, :cart_not_found} = Checkout.get_cart_with_details(session_id)
    end
  end

  describe "checkout/1" do
    test "creates checkout session with token and fees", %{
      session_id: session_id,
      ticket_type: ticket_type
    } do
      {:ok, _} = Carts.get_or_create_cart(session_id)
      {:ok, _} = Carts.add_item(session_id, ticket_type.id, 2)

      {:ok, checkout_session} = Checkout.checkout(session_id)

      assert checkout_session.session_id == session_id
      assert checkout_session.status == "pending_payment"
      assert is_binary(checkout_session.checkout_token)
      assert String.length(checkout_session.checkout_token) > 0
      assert length(checkout_session.line_items) == 1
      assert checkout_session.fees.subtotal == Decimal.new("100.00")
      assert DateTime.compare(checkout_session.expires_at, DateTime.utc_now()) == :gt
    end

    test "returns error for empty cart", %{session_id: session_id} do
      {:ok, _} = Carts.get_or_create_cart(session_id)

      assert {:error, :cart_empty} = Checkout.checkout(session_id)
    end

    test "returns error for non-existent cart", %{session_id: session_id} do
      assert {:error, :cart_not_found} = Checkout.checkout(session_id)
    end
  end
end
