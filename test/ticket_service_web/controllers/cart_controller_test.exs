defmodule TicketServiceWeb.CartControllerTest do
  use TicketServiceWeb.ConnCase

  alias TicketService.Carts

  setup %{conn: conn} do
    {:ok, venue} =
      TicketService.Venues.create_venue(%{
        name: "Test Arena",
        address: "123 Test St",
        capacity: 1000
      })

    {:ok, event} =
      TicketService.Events.create_event(%{
        title: "Test Concert",
        description: "A test event",
        category: "concert",
        starts_at: DateTime.add(DateTime.utc_now(), 86400, :second),
        ends_at: DateTime.add(DateTime.utc_now(), 90000, :second),
        venue_id: venue.id
      })

    {:ok, ticket_type} =
      TicketService.Tickets.create_ticket_type(%{
        name: "VIP Pass",
        price: Decimal.new("150.00"),
        quantity: 50,
        event_id: event.id
      })

    session_id = "ctrl-test-#{System.unique_integer([:positive])}"

    %{
      conn: put_req_header(conn, "accept", "application/json"),
      venue: venue,
      event: event,
      ticket_type: ticket_type,
      session_id: session_id
    }
  end

  describe "GET /api/carts/:session_id" do
    test "returns enriched cart with fees", %{conn: conn, session_id: session_id, ticket_type: tt} do
      {:ok, _} = Carts.get_or_create_cart(session_id)
      {:ok, _} = Carts.add_item(session_id, tt.id, 2)

      conn = get(conn, "/api/carts/#{session_id}")
      data = json_response(conn, 200)["data"]

      assert data["session_id"] == session_id
      assert data["item_count"] == 1
      assert data["total_tickets"] == 2
      assert length(data["line_items"]) == 1

      [item] = data["line_items"]
      assert item["ticket_type_id"] == tt.id
      assert item["ticket_type_name"] == "VIP Pass"
      assert item["quantity"] == 2
      assert item["unit_price"] == "150.00"

      fees = data["fees"]
      assert fees["subtotal"] == "300.00"
      assert fees["total_tickets"] == 2
      assert fees["platform_fee"] != nil
      assert fees["processing_fee"] != nil
      assert fees["total"] != nil

      assert data["ttl_remaining_seconds"] > 0
    end

    test "returns 404 for non-existent cart", %{conn: conn} do
      conn = get(conn, "/api/carts/nonexistent-session")
      assert json_response(conn, 404)["error"] == "Cart not found"
    end
  end

  describe "POST /api/carts/:session_id/checkout" do
    test "creates order from cart", %{conn: conn, session_id: session_id, ticket_type: tt} do
      {:ok, _} = Carts.get_or_create_cart(session_id)
      {:ok, _} = Carts.add_item(session_id, tt.id, 1)

      conn = post(conn, "/api/carts/#{session_id}/checkout")
      data = json_response(conn, 201)["data"]

      assert is_binary(data["checkout_token"])
      assert is_binary(data["order_id"])
      assert data["subtotal"] == "150.00"
      assert data["checkout_expires_at"] != nil
    end

    test "returns 422 for empty cart", %{conn: conn, session_id: session_id} do
      {:ok, _} = Carts.get_or_create_cart(session_id)

      conn = post(conn, "/api/carts/#{session_id}/checkout")
      assert json_response(conn, 422)["error"] == "Cart is empty"
    end

    test "returns 404 for non-existent cart", %{conn: conn} do
      conn = post(conn, "/api/carts/nonexistent-session/checkout")
      assert json_response(conn, 404)["error"] == "Cart not found"
    end
  end
end
