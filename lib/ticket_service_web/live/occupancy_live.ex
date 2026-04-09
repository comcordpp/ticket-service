defmodule TicketServiceWeb.OccupancyLive do
  use TicketServiceWeb, :live_view

  alias TicketService.Occupancy

  @impl true
  def mount(%{"venue_id" => venue_id}, _session, socket) do
    if connected?(socket) do
      Occupancy.subscribe(venue_id)
    end

    sections = Occupancy.get_venue_breakdown(venue_id)
    total = Occupancy.get_venue_total(venue_id)
    capacity = Occupancy.get_venue_capacity(venue_id)

    socket =
      socket
      |> assign(:venue_id, venue_id)
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
  def render(assigns) do
    ~H"""
    <div class="header">
      <h1>Occupancy Dashboard</h1>
      <div>
        <span class={if @connected, do: "connected", else: "disconnected"}>
          <%= if @connected, do: "● Live", else: "○ Disconnected" %>
        </span>
        <span class="timestamp" style="margin-left: 1rem;">
          Venue: <%= @venue_id %>
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
            <% :not_set -> %>people (no capacity set)
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
        <h2>Sections Active</h2>
        <div class="stat-value"><%= length(@sections) %></div>
        <div class="stat-label">sections with occupancy</div>
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
      <%= if @sections == [] do %>
        <p style="color: #64748b; padding: 2rem 0; text-align: center;">No occupancy data yet.</p>
      <% else %>
        <table>
          <thead>
            <tr>
              <th>Section ID</th>
              <th>Count</th>
              <th>Status</th>
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
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
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
