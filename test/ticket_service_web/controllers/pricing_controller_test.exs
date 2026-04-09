defmodule TicketServiceWeb.PricingControllerTest do
  use TicketServiceWeb.ConnCase

  alias TicketService.Repo
  alias TicketService.Carts
  alias TicketService.Pricing.FeeConfig

  setup do
    {:ok, venue} =
      %TicketService.Venues.Venue{}
      |> TicketService.Venues.Venue.changeset(%{name: "Test Arena", location: "NYC", capacity: 1000})
      |> Repo.insert()

    {:ok, event} =
      %TicketService.Events.Event{}
      |> TicketService.Events.Event.changeset(%{
        title: "Test Concert",
        description: "A test",
        category: "music",
        status: "published",
        starts_at: DateTime.add(DateTime.utc_now(), 86400, :second),
        ends_at: DateTime.add(DateTime.utc_now(), 90000, :second),
        venue_id: venue.id
      })
      |> Repo.insert()

    {:ok, ticket_type} =
      %TicketService.Tickets.TicketType{}
      |> TicketService.Tickets.TicketType.changeset(%{
        name: "General Admission",
        price: Decimal.new("50.00"),
        quantity: 100,
        event_id: event.id
      })
      |> Repo.insert()

    session_id = "test-session-#{System.unique_integer([:positive])}"

    %{event: event, ticket_type: ticket_type, session_id: session_id}
  end

  describe "GET /api/carts/:session_id/pricing" do
    test "returns itemized fee breakdown", %{conn: conn, ticket_type: tt, session_id: sid} do
      {:ok, _} = Carts.get_or_create_cart(sid)
      {:ok, _} = Carts.add_item(sid, tt.id, 2)

      conn = get(conn, "/api/carts/#{sid}/pricing")
      assert %{"data" => data} = json_response(conn, 200)

      assert data["subtotal_cents"] == 10000
      assert data["service_fee_cents"] == 1000
      assert data["platform_fee_cents"] == 150
      assert data["tax_cents"] == 0
      assert data["total_cents"] == 11150
      assert data["currency"] == "USD"

      assert [item] = data["items"]
      assert item["ticket_type_id"] == tt.id
      assert item["ticket_type_name"] == "General Admission"
      assert item["quantity"] == 2
      assert item["base_price_cents"] == 5000
      assert item["line_total_cents"] == 10000
      assert item["service_fee_cents"] == 1000
    end

    test "uses custom fee config when set", %{conn: conn, event: event, ticket_type: tt, session_id: sid} do
      Repo.insert!(%FeeConfig{
        event_id: event.id,
        service_fee_pct: Decimal.new("15.0"),
        platform_fee_flat: 200,
        platform_fee_pct: Decimal.new("0.0"),
        tax_rate: Decimal.new("10.0")
      })

      {:ok, _} = Carts.get_or_create_cart(sid)
      {:ok, _} = Carts.add_item(sid, tt.id, 1)

      conn = get(conn, "/api/carts/#{sid}/pricing")
      assert %{"data" => data} = json_response(conn, 200)

      assert data["subtotal_cents"] == 5000
      assert data["service_fee_cents"] == 750
      assert data["platform_fee_cents"] == 200
      # tax: (5000 + 750 + 200) * 0.10 = 595
      assert data["tax_cents"] == 595
      assert data["total_cents"] == 5000 + 750 + 200 + 595

      assert data["fee_rates"]["service_fee_pct"] == "15.0"
      assert data["fee_rates"]["tax_rate"] == "10.0"
    end

    test "returns 404 for non-existent cart", %{conn: conn} do
      conn = get(conn, "/api/carts/nonexistent/pricing")
      assert json_response(conn, 404)["error"] =~ "not found"
    end

    test "returns 422 for empty cart", %{conn: conn, session_id: sid} do
      {:ok, _} = Carts.get_or_create_cart(sid)

      conn = get(conn, "/api/carts/#{sid}/pricing")
      assert json_response(conn, 422)["error"] =~ "empty"
    end
  end
end
