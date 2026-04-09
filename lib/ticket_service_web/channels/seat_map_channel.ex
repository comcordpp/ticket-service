defmodule TicketServiceWeb.SeatMapChannel do
  @moduledoc """
  RT-1: Live Seat Map channel.

  Broadcasts seat status changes (available/held/sold) to all connected
  clients within 500ms. Color-coded updates for real-time seat map UI.
  """
  use Phoenix.Channel

  alias TicketService.Seating

  @impl true
  def join("seat_map:" <> event_id, _params, socket) do
    socket = assign(socket, :event_id, event_id)

    # Send initial seat map state
    send(self(), :send_initial_state)

    {:ok, socket}
  end

  @impl true
  def handle_info(:send_initial_state, socket) do
    event_id = socket.assigns.event_id
    seats = Seating.get_seat_map(event_id)

    push(socket, "seat_map:initial", %{
      seats: format_seats(seats)
    })

    {:noreply, socket}
  end

  @impl true
  def handle_info({:seat_update, seat_data}, socket) do
    push(socket, "seat_map:update", seat_data)
    {:noreply, socket}
  end

  @doc """
  Broadcast a seat status change to all subscribers of an event's seat map.
  Called from Seating context when seat status changes.
  """
  def broadcast_seat_update(event_id, seat_updates) when is_list(seat_updates) do
    TicketServiceWeb.Endpoint.broadcast(
      "seat_map:#{event_id}",
      "seat_map:update",
      %{updates: seat_updates}
    )
  end

  def broadcast_seat_update(event_id, seat_update) do
    broadcast_seat_update(event_id, [seat_update])
  end

  defp format_seats(seats) do
    Enum.map(seats, fn seat ->
      %{
        id: seat.id,
        section_id: seat.section_id,
        row_label: seat.row_label,
        seat_number: seat.seat_number,
        status: seat.status,
        color: status_color(seat.status)
      }
    end)
  end

  defp status_color("available"), do: "#4CAF50"
  defp status_color("held"), do: "#FFC107"
  defp status_color("sold"), do: "#F44336"
  defp status_color(_), do: "#9E9E9E"
end
