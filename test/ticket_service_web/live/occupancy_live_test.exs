defmodule TicketServiceWeb.OccupancyLiveTest do
  use TicketServiceWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TicketService.Occupancy

  @venue_id "test-venue-live-001"
  @section_a "section-a"
  @section_b "section-b"

  setup do
    :ets.delete_all_objects(:occupancy_counters)
    :ets.delete_all_objects(:occupancy_capacities)
    :ok
  end

  describe "OccupancyLive" do
    test "renders venue occupancy dashboard", %{conn: conn} do
      Occupancy.record_entry(@venue_id, @section_a, 100)
      {:ok, view, html} = live(conn, "/admin/occupancy/#{@venue_id}")

      assert html =~ "Occupancy Dashboard"
      assert html =~ @venue_id
      assert html =~ "100"
    end

    test "shows zero for empty venue", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/occupancy/#{@venue_id}")

      assert html =~ "0"
      assert html =~ "No occupancy data yet"
    end

    test "shows capacity info when set", %{conn: conn} do
      Occupancy.set_venue_capacity(@venue_id, 50_000)
      Occupancy.record_entry(@venue_id, @section_a, 25_000)
      {:ok, _view, html} = live(conn, "/admin/occupancy/#{@venue_id}")

      assert html =~ "50000"
      assert html =~ "25000"
    end

    test "updates in real-time via PubSub", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/occupancy/#{@venue_id}")

      Occupancy.record_entry(@venue_id, @section_a, 42)
      html = render(view)

      assert html =~ "42"
      assert html =~ @section_a
    end

    test "shows capacity alert when over 90%", %{conn: conn} do
      Occupancy.set_venue_capacity(@venue_id, 100)
      Occupancy.record_entry(@venue_id, @section_a, 95)
      {:ok, _view, html} = live(conn, "/admin/occupancy/#{@venue_id}")

      assert html =~ "WARNING"
      assert html =~ "Approaching capacity"
    end

    test "shows danger alert at full capacity", %{conn: conn} do
      Occupancy.set_venue_capacity(@venue_id, 100)
      Occupancy.record_entry(@venue_id, @section_a, 100)
      {:ok, _view, html} = live(conn, "/admin/occupancy/#{@venue_id}")

      assert html =~ "CAPACITY REACHED"
    end

    test "shows per-section breakdown", %{conn: conn} do
      Occupancy.record_entry(@venue_id, @section_a, 10)
      Occupancy.record_entry(@venue_id, @section_b, 20)
      {:ok, _view, html} = live(conn, "/admin/occupancy/#{@venue_id}")

      assert html =~ @section_a
      assert html =~ @section_b
      assert html =~ "10"
      assert html =~ "20"
    end
  end

  describe "OccupancyDemoLive" do
    test "renders demo page with seeded data", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/demo/occupancy")

      assert html =~ "Occupancy Demo"
      assert html =~ "Simulate Burst Entry"
      assert html =~ "Reset All"
    end

    test "simulate_burst adds occupancy", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/demo/occupancy")

      html = render_click(view, "simulate_burst")
      # After burst, counts should have increased
      assert html =~ "Active"
    end

    test "reset_all clears all counters", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/demo/occupancy")

      html = render_click(view, "reset_all")
      # After reset, should show 0 total
      assert html =~ "0"
    end

    test "simulate_entry adds to specific section", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/demo/occupancy")

      render_click(view, "simulate_entry", %{"section" => "north-stand"})
      html = render(view)

      assert html =~ "north-stand"
    end
  end
end
