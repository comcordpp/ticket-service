defmodule TicketServiceWeb.OccupancyDemoLive do
  use TicketServiceWeb, :live_view

  alias TicketService.Occupancy

  @demo_venue_id "demo-venue-001"
  @demo_sections ["north-stand", "south-stand", "east-stand", "west-stand", "vip-lounge"]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Occupancy.subscribe(@demo_venue_id)
      Occupancy.set_venue_capacity(@demo_venue_id, 50_000)

      # Seed demo data
      for {section, count} <- Enum.zip(@demo_sections, [8_500, 7_200, 6_800, 9_100, 450]) do
        Occupancy.reset_section(@demo_venue_id, section)
        Occupancy.record_entry(@demo_venue_id, section, count)
      end
    end

    sections = Occupancy.get_venue_breakdown(@demo_venue_id)
    total = Occupancy.get_venue_total(@demo_venue_id)
    capacity = Occupancy.get_venue_capacity(@demo_venue_id)

    socket =
      socket
      |> assign(:venue_id, @demo_venue_id)
      |> assign(:sections, sections)
      |> assign(:total, total)
      |> assign(:capacity, capacity)
      |> assign(:last_updated, DateTime.utc_now())
      |> assign(:connected, connected?(socket))

    {:ok, socket}
  end

  @impl true
  def handle_info({:occupancy_update, payload}, socket) do
    sections = Occupancy.get_venue_breakdown(socket.assigns.venue_id)

    socket =
      socket
      |> assign(:sections, sections)
      |> assign(:total, payload.venue_total)
      |> assign(:last_updated, payload.timestamp)

    {:noreply, socket}
  end

  @impl true
  def handle_info({:capacity_reached, _payload}, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("simulate_entry", %{"section" => section}, socket) do
    count = Enum.random(1..50)
    Occupancy.record_entry(@demo_venue_id, section, count)
    {:noreply, socket}
  end

  @impl true
  def handle_event("simulate_exit", %{"section" => section}, socket) do
    count = Enum.random(1..30)
    Occupancy.record_exit(@demo_venue_id, section, count)
    {:noreply, socket}
  end

  @impl true
  def handle_event("simulate_burst", _params, socket) do
    for section <- @demo_sections do
      count = Enum.random(100..500)
      Occupancy.record_entry(@demo_venue_id, section, count)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("reset_all", _params, socket) do
    Occupancy.reset_venue(@demo_venue_id)
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="header">
      <h1>Occupancy Demo — Live Counter POC</h1>
      <div>
        <span class={if @connected, do: "connected", else: "disconnected"}>
          <%= if @connected, do: "● Live", else: "○ Disconnected" %>
        </span>
      </div>
    </div>

    <%= if capacity_alert?(@total, @capacity) do %>
      <div class={alert_class(@total, @capacity)}>
        <%= alert_message(@total, @capacity) %>
      </div>
    <% end %>

    <div class="grid">
      <div class="card">
        <h2>Total Occupancy</h2>
        <div class="stat-value"><%= @total %></div>
        <div class="stat-label">
          <%= case @capacity do %>
            <% {:ok, cap} -> %>people / <%= cap %> capacity
            <% :not_set -> %>people
          <% end %>
        </div>
        <%= if match?({:ok, _}, @capacity) do %>
          <div class="progress-bar">
            <div class={"progress-fill #{fill_color(@total, @capacity)}"} style={"width: #{utilization_pct(@total, @capacity)}%"}>
            </div>
          </div>
        <% end %>
      </div>

      <div class="card">
        <h2>Simulation Controls</h2>
        <div style="display: flex; gap: 0.5rem; flex-wrap: wrap; margin-top: 0.5rem;">
          <button phx-click="simulate_burst" style="padding: 0.5rem 1rem; background: #2563eb; color: white; border: none; border-radius: 0.375rem; cursor: pointer; font-weight: 600;">
            Simulate Burst Entry
          </button>
          <button phx-click="reset_all" style="padding: 0.5rem 1rem; background: #dc2626; color: white; border: none; border-radius: 0.375rem; cursor: pointer; font-weight: 600;">
            Reset All
          </button>
        </div>
      </div>

      <div class="card">
        <h2>Last Updated</h2>
        <div class="stat-value" style="font-size: 1.5rem;">
          <%= Calendar.strftime(@last_updated, "%H:%M:%S") %>
        </div>
        <div class="stat-label"><%= Calendar.strftime(@last_updated, "%Y-%m-%d") %></div>
      </div>
    </div>

    <div class="card">
      <h2>Section Breakdown</h2>
      <table>
        <thead>
          <tr>
            <th>Section</th>
            <th>Count</th>
            <th>Status</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          <%= for section <- Enum.sort_by(@sections, & &1.count, :desc) do %>
            <tr>
              <td><code><%= section.section_id %></code></td>
              <td><%= section.count %></td>
              <td>
                <span class={"badge #{if section.count > 0, do: "badge-green", else: "badge-red"}"}>
                  <%= if section.count > 0, do: "Active", else: "Empty" %>
                </span>
              </td>
              <td>
                <button phx-click="simulate_entry" phx-value-section={section.section_id}
                  style="padding: 0.25rem 0.5rem; background: #166534; color: #86efac; border: none; border-radius: 0.25rem; cursor: pointer; margin-right: 0.25rem; font-size: 0.8rem;">
                  + Entry
                </button>
                <button phx-click="simulate_exit" phx-value-section={section.section_id}
                  style="padding: 0.25rem 0.5rem; background: #7f1d1d; color: #fca5a5; border: none; border-radius: 0.25rem; cursor: pointer; font-size: 0.8rem;">
                  - Exit
                </button>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  defp capacity_alert?(total, {:ok, capacity}) when total >= capacity, do: true
  defp capacity_alert?(total, {:ok, capacity}) when total >= capacity * 0.9, do: true
  defp capacity_alert?(_total, _capacity), do: false

  defp alert_class(total, {:ok, capacity}) when total >= capacity, do: "alert alert-danger"
  defp alert_class(_total, _capacity), do: "alert alert-warning"

  defp alert_message(total, {:ok, capacity}) when total >= capacity do
    "CAPACITY REACHED — #{total}/#{capacity} (#{Float.round(total / capacity * 100, 1)}%)"
  end

  defp alert_message(total, {:ok, capacity}) do
    "WARNING — Approaching capacity: #{total}/#{capacity} (#{Float.round(total / capacity * 100, 1)}%)"
  end

  defp utilization_pct(total, {:ok, capacity}) when capacity > 0 do
    min(Float.round(total / capacity * 100, 1), 100)
  end

  defp utilization_pct(_total, _capacity), do: 0

  defp fill_color(total, {:ok, capacity}) when total >= capacity, do: "fill-red"
  defp fill_color(total, {:ok, capacity}) when total >= capacity * 0.9, do: "fill-yellow"
  defp fill_color(_total, _capacity), do: "fill-green"
end
