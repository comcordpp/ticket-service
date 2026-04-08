defmodule TicketServiceWeb.EventControllerTest do
  use TicketServiceWeb.ConnCase, async: true

  alias TicketService.Events
  alias TicketService.Tickets

  @event_attrs %{
    title: "Test Concert",
    description: "A test event",
    category: "music",
    starts_at: "2026-07-15T18:00:00Z",
    ends_at: "2026-07-15T23:00:00Z"
  }

  describe "POST /api/events" do
    test "creates an event", %{conn: conn} do
      conn = post(conn, "/api/events", event: @event_attrs)
      assert %{"data" => %{"id" => id, "title" => "Test Concert", "status" => "draft"}} =
               json_response(conn, 201)
      assert id
    end

    test "returns errors for invalid data", %{conn: conn} do
      conn = post(conn, "/api/events", event: %{})
      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors["title"]
    end
  end

  describe "GET /api/events" do
    test "lists events", %{conn: conn} do
      {:ok, _} = Events.create_event(%{title: "Event 1", starts_at: ~U[2026-07-15 18:00:00Z]})
      conn = get(conn, "/api/events")
      assert %{"data" => events} = json_response(conn, 200)
      assert length(events) == 1
    end
  end

  describe "GET /api/events/:id" do
    test "returns event with details", %{conn: conn} do
      {:ok, event} = Events.create_event(%{title: "Show", starts_at: ~U[2026-07-15 18:00:00Z]})
      conn = get(conn, "/api/events/#{event.id}")
      assert %{"data" => %{"id" => _, "title" => "Show", "ticket_types" => []}} =
               json_response(conn, 200)
    end

    test "returns 404 for unknown event", %{conn: conn} do
      conn = get(conn, "/api/events/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end
  end

  describe "PUT /api/events/:id" do
    test "updates an event", %{conn: conn} do
      {:ok, event} = Events.create_event(%{title: "Old", starts_at: ~U[2026-07-15 18:00:00Z]})
      conn = put(conn, "/api/events/#{event.id}", event: %{title: "New"})
      assert %{"data" => %{"title" => "New"}} = json_response(conn, 200)
    end
  end

  describe "DELETE /api/events/:id" do
    test "deletes an event", %{conn: conn} do
      {:ok, event} = Events.create_event(%{title: "Gone", starts_at: ~U[2026-07-15 18:00:00Z]})
      conn = delete(conn, "/api/events/#{event.id}")
      assert response(conn, 204)
    end
  end

  describe "POST /api/events/:id/publish" do
    test "publishes a draft event with ticket types", %{conn: conn} do
      {:ok, event} = Events.create_event(%{title: "Show", starts_at: ~U[2026-07-15 18:00:00Z]})
      {:ok, _} = Tickets.create_ticket_type(%{name: "GA", price: 25, quantity: 100, event_id: event.id})
      conn = post(conn, "/api/events/#{event.id}/publish")
      assert %{"data" => %{"status" => "published"}} = json_response(conn, 200)
    end

    test "rejects publishing without ticket types", %{conn: conn} do
      {:ok, event} = Events.create_event(%{title: "Show", starts_at: ~U[2026-07-15 18:00:00Z]})
      conn = post(conn, "/api/events/#{event.id}/publish")
      assert %{"error" => _} = json_response(conn, 422)
    end
  end

  describe "POST /api/events/:id/cancel" do
    test "cancels an event", %{conn: conn} do
      {:ok, event} = Events.create_event(%{title: "Show", starts_at: ~U[2026-07-15 18:00:00Z]})
      conn = post(conn, "/api/events/#{event.id}/cancel")
      assert %{"data" => %{"status" => "cancelled"}} = json_response(conn, 200)
    end
  end
end
