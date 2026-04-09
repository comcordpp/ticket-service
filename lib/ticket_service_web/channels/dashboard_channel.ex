defmodule TicketServiceWeb.DashboardChannel do
  @moduledoc """
  DA-1: Sales Overview Dashboard channel.

  Provides real-time sales metrics: sold/available/held counts,
  gross and net revenue. Updates pushed on every order confirmation.
  """
  use Phoenix.Channel

  import Ecto.Query
  alias TicketService.Repo

  @impl true
  def join("dashboard:" <> event_id, _params, socket) do
    socket = assign(socket, :event_id, event_id)

    # Send initial dashboard data
    send(self(), :send_dashboard)

    {:ok, socket}
  end

  @impl true
  def handle_info(:send_dashboard, socket) do
    data = build_dashboard(socket.assigns.event_id)
    push(socket, "dashboard:update", data)
    {:noreply, socket}
  end

  @impl true
  def handle_in("refresh", _params, socket) do
    data = build_dashboard(socket.assigns.event_id)
    push(socket, "dashboard:update", data)
    {:noreply, socket}
  end

  @doc "Broadcast dashboard update to all subscribers."
  def broadcast_update(event_id) do
    Task.start(fn ->
      data = build_dashboard(event_id)
      TicketServiceWeb.Endpoint.broadcast("dashboard:#{event_id}", "dashboard:update", data)
    end)
  end

  defp build_dashboard(event_id) do
    seat_stats = get_seat_stats(event_id)
    ticket_stats = get_ticket_stats(event_id)
    revenue = get_revenue(event_id)

    %{
      event_id: event_id,
      seats: seat_stats,
      tickets: ticket_stats,
      revenue: revenue,
      updated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp get_seat_stats(event_id) do
    query =
      from s in TicketService.Seating.Seat,
        join: sec in TicketService.Seating.Section, on: s.section_id == sec.id,
        join: v in TicketService.Venues.Venue, on: sec.venue_id == v.id,
        join: e in TicketService.Events.Event, on: e.venue_id == v.id,
        where: e.id == ^event_id,
        group_by: s.status,
        select: {s.status, count(s.id)}

    stats = Repo.all(query) |> Map.new()

    %{
      available: Map.get(stats, "available", 0),
      held: Map.get(stats, "held", 0),
      sold: Map.get(stats, "sold", 0),
      total: Map.values(stats) |> Enum.sum()
    }
  end

  defp get_ticket_stats(event_id) do
    query =
      from tt in TicketService.Tickets.TicketType,
        where: tt.event_id == ^event_id,
        select: %{
          total_quantity: sum(tt.quantity),
          total_sold: sum(tt.sold_count)
        }

    case Repo.one(query) do
      %{total_quantity: qty, total_sold: sold} ->
        qty = qty || 0
        sold = sold || 0
        %{total: qty, sold: sold, available: qty - sold}

      nil ->
        %{total: 0, sold: 0, available: 0}
    end
  end

  defp get_revenue(event_id) do
    query =
      from o in TicketService.Orders.Order,
        where: o.event_id == ^event_id and o.status == "confirmed",
        select: %{
          gross: sum(o.total),
          subtotal: sum(o.subtotal),
          platform_fees: sum(o.platform_fee),
          processing_fees: sum(o.processing_fee),
          order_count: count(o.id)
        }

    case Repo.one(query) do
      %{gross: gross, subtotal: sub, platform_fees: pf, processing_fees: proc, order_count: cnt} ->
        %{
          gross: gross || Decimal.new(0),
          net: sub || Decimal.new(0),
          platform_fees: pf || Decimal.new(0),
          processing_fees: proc || Decimal.new(0),
          order_count: cnt || 0
        }

      nil ->
        %{gross: Decimal.new(0), net: Decimal.new(0), platform_fees: Decimal.new(0), processing_fees: Decimal.new(0), order_count: 0}
    end
  end
end
