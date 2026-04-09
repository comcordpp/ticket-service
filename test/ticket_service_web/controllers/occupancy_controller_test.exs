defmodule TicketServiceWeb.OccupancyControllerTest do
  use TicketServiceWeb.ConnCase, async: false

  @venue_id "00000000-0000-0000-0000-000000000001"
  @section_id "00000000-0000-0000-0000-00000000000a"

  setup do
    :ets.delete_all_objects(:occupancy_counters)
    :ets.delete_all_objects(:occupancy_capacities)
    :ok
  end

  describe "POST /api/occupancy/entry" do
    test "records an entry and returns updated count", %{conn: conn} do
      conn =
        post(conn, "/api/occupancy/entry", %{
          "venue_id" => @venue_id,
          "section_id" => @section_id,
          "gate_id" => "gate-A"
        })

      assert %{"data" => data} = json_response(conn, 200)
      assert data["venue_id"] == @venue_id
      assert data["section_id"] == @section_id
      assert data["count"] == 1
      assert data["venue_total"] == 1
    end

    test "increments on multiple entries", %{conn: conn} do
      post(conn, "/api/occupancy/entry", %{"venue_id" => @venue_id, "section_id" => @section_id})
      post(conn, "/api/occupancy/entry", %{"venue_id" => @venue_id, "section_id" => @section_id})
      conn = post(conn, "/api/occupancy/entry", %{"venue_id" => @venue_id, "section_id" => @section_id})

      assert %{"data" => %{"count" => 3}} = json_response(conn, 200)
    end

    test "uses default section_id when not provided", %{conn: conn} do
      conn = post(conn, "/api/occupancy/entry", %{"venue_id" => @venue_id})

      assert %{"data" => %{"section_id" => "default"}} = json_response(conn, 200)
    end

    test "supports batch count", %{conn: conn} do
      conn = post(conn, "/api/occupancy/entry", %{"venue_id" => @venue_id, "section_id" => @section_id, "count" => 5})

      assert %{"data" => %{"count" => 5}} = json_response(conn, 200)
    end

    test "returns error when venue_id missing", %{conn: conn} do
      conn = post(conn, "/api/occupancy/entry", %{})

      assert %{"error" => "venue_id is required"} = json_response(conn, 400)
    end
  end

  describe "POST /api/occupancy/exit" do
    test "records an exit and returns updated count", %{conn: conn} do
      post(conn, "/api/occupancy/entry", %{"venue_id" => @venue_id, "section_id" => @section_id})
      post(conn, "/api/occupancy/entry", %{"venue_id" => @venue_id, "section_id" => @section_id})
      conn = post(conn, "/api/occupancy/exit", %{"venue_id" => @venue_id, "section_id" => @section_id})

      assert %{"data" => %{"count" => 1, "venue_total" => 1}} = json_response(conn, 200)
    end

    test "does not go below zero", %{conn: conn} do
      conn = post(conn, "/api/occupancy/exit", %{"venue_id" => @venue_id, "section_id" => @section_id})

      assert %{"data" => %{"count" => 0}} = json_response(conn, 200)
    end

    test "returns error when venue_id missing", %{conn: conn} do
      conn = post(conn, "/api/occupancy/exit", %{})

      assert %{"error" => "venue_id is required"} = json_response(conn, 400)
    end
  end

  describe "GET /api/occupancy/:venue_id" do
    test "returns venue total", %{conn: conn} do
      post(conn, "/api/occupancy/entry", %{"venue_id" => @venue_id, "section_id" => @section_id, "count" => 10})
      conn = get(conn, "/api/occupancy/#{@venue_id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["venue_id"] == @venue_id
      assert data["total"] == 10
    end

    test "includes capacity and utilization when set", %{conn: conn} do
      TicketService.Occupancy.set_venue_capacity(@venue_id, 100)
      post(conn, "/api/occupancy/entry", %{"venue_id" => @venue_id, "section_id" => @section_id, "count" => 50})
      conn = get(conn, "/api/occupancy/#{@venue_id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["capacity"] == 100
      assert data["utilization"] == 50.0
    end

    test "returns 0 for unknown venue", %{conn: conn} do
      conn = get(conn, "/api/occupancy/unknown-venue-id")

      assert %{"data" => %{"total" => 0}} = json_response(conn, 200)
    end
  end

  describe "GET /api/occupancy/:venue_id/sections" do
    test "returns per-section breakdown", %{conn: conn} do
      section_b = "00000000-0000-0000-0000-00000000000b"
      post(conn, "/api/occupancy/entry", %{"venue_id" => @venue_id, "section_id" => @section_id, "count" => 10})
      post(conn, "/api/occupancy/entry", %{"venue_id" => @venue_id, "section_id" => section_b, "count" => 20})
      conn = get(conn, "/api/occupancy/#{@venue_id}/sections")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["total"] == 30
      assert length(data["sections"]) == 2
    end

    test "returns empty sections for unknown venue", %{conn: conn} do
      conn = get(conn, "/api/occupancy/unknown/sections")

      assert %{"data" => %{"total" => 0, "sections" => []}} = json_response(conn, 200)
    end
  end
end
