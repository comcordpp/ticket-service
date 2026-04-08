defmodule TicketServiceWeb.VenueControllerTest do
  use TicketServiceWeb.ConnCase, async: true

  alias TicketService.Venues

  describe "POST /api/venues" do
    test "creates a venue", %{conn: conn} do
      conn = post(conn, "/api/venues", venue: %{name: "Arena", address: "123 Main St", capacity: 5000})
      assert %{"data" => %{"id" => _, "name" => "Arena", "capacity" => 5000}} =
               json_response(conn, 201)
    end

    test "returns errors for invalid data", %{conn: conn} do
      conn = post(conn, "/api/venues", venue: %{})
      assert %{"errors" => _} = json_response(conn, 422)
    end
  end

  describe "GET /api/venues" do
    test "lists venues", %{conn: conn} do
      {:ok, _} = Venues.create_venue(%{name: "Arena", capacity: 5000})
      conn = get(conn, "/api/venues")
      assert %{"data" => venues} = json_response(conn, 200)
      assert length(venues) == 1
    end
  end

  describe "GET /api/venues/:id" do
    test "returns venue with sections", %{conn: conn} do
      {:ok, venue} = Venues.create_venue(%{name: "Arena", capacity: 5000})
      conn = get(conn, "/api/venues/#{venue.id}")
      assert %{"data" => %{"name" => "Arena", "sections" => []}} = json_response(conn, 200)
    end
  end

  describe "PUT /api/venues/:id" do
    test "updates a venue", %{conn: conn} do
      {:ok, venue} = Venues.create_venue(%{name: "Old", capacity: 100})
      conn = put(conn, "/api/venues/#{venue.id}", venue: %{name: "New"})
      assert %{"data" => %{"name" => "New"}} = json_response(conn, 200)
    end
  end
end
