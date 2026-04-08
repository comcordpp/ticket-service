defmodule TicketService.EventsCancelEditTest do
  use TicketService.DataCase

  alias TicketService.Events
  alias TicketService.Venues
  alias TicketService.Tickets
  alias TicketService.Carts
  alias TicketService.Orders

  setup do
    {:ok, venue} =
      Venues.create_venue(%{name: "Test Venue", address: "123 St", capacity: 500})

    {:ok, event} =
      Events.create_event(%{
        title: "Cancellable Event",
        description: "Test event for cancel/edit",
        category: "concert",
        starts_at: DateTime.add(DateTime.utc_now(), 86400, :second),
        ends_at: DateTime.add(DateTime.utc_now(), 90000, :second),
        venue_id: venue.id
      })

    {:ok, ticket_type} =
      Tickets.create_ticket_type(%{
        name: "Standard",
        price: Decimal.new("50.00"),
        quantity: 100,
        event_id: event.id
      })

    {:ok, published} = Events.publish_event(event)

    %{venue: venue, event: published, ticket_type: ticket_type}
  end

  describe "update_event/2 with field locking" do
    test "allows editing title and description on published event without sales", %{event: event} do
      {:ok, updated} = Events.update_event(event, %{title: "New Title", description: "Updated"})
      assert updated.title == "New Title"
      assert updated.description == "Updated"
    end

    test "locks venue_id, starts_at, category after sales", %{event: event, ticket_type: tt} do
      # Create a sale
      session_id = "lock-test-#{System.unique_integer([:positive])}"
      {:ok, _} = Carts.get_or_create_cart(session_id)
      {:ok, _} = Carts.add_item(session_id, tt.id, 1)
      {:ok, order} = Orders.checkout(session_id)
      {:ok, _} = Orders.confirm_order(order)

      # Now try to edit locked fields
      {:error, changeset} = Events.update_event(event, %{category: "sports"})
      assert changeset.errors[:category]

      # But title/description should still be editable
      {:ok, updated} = Events.update_event(event, %{title: "Still Editable"})
      assert updated.title == "Still Editable"
    end

    test "rejects updates to cancelled events", %{event: event} do
      {:ok, cancelled} = Events.cancel_event(event)
      assert {:error, :event_cancelled} = Events.update_event(cancelled, %{title: "Nope"})
    end
  end

  describe "cancel_event/1" do
    test "cancels event and batch refunds orders", %{event: event, ticket_type: tt} do
      # Create and confirm an order
      session_id = "cancel-test-#{System.unique_integer([:positive])}"
      {:ok, _} = Carts.get_or_create_cart(session_id)
      {:ok, _} = Carts.add_item(session_id, tt.id, 2)
      {:ok, order} = Orders.checkout(session_id)
      {:ok, _confirmed} = Orders.confirm_order(order)

      # Cancel the event
      {:ok, cancelled} = Events.cancel_event(event)
      assert cancelled.status == "cancelled"

      # Verify the order was cancelled
      refunded_order = Orders.get_order(order.id)
      assert refunded_order.status == "cancelled"
    end

    test "prevents double cancellation", %{event: event} do
      {:ok, _cancelled} = Events.cancel_event(event)
      assert {:error, :already_cancelled} = Events.cancel_event(%{event | status: "cancelled"})
    end

    test "cancels pending orders too", %{event: event, ticket_type: tt} do
      # Create a pending order (not confirmed)
      session_id = "pending-cancel-#{System.unique_integer([:positive])}"
      {:ok, _} = Carts.get_or_create_cart(session_id)
      {:ok, _} = Carts.add_item(session_id, tt.id, 1)
      {:ok, order} = Orders.checkout(session_id)

      # Cancel the event
      {:ok, _} = Events.cancel_event(event)

      # Verify the pending order was cancelled
      cancelled_order = Orders.get_order(order.id)
      assert cancelled_order.status == "cancelled"
    end
  end
end
