defmodule TicketServiceWeb.OrderController do
  @moduledoc """
  DA-3: Order Management controller.

  Search, detail view with tickets, payment status, and refund history.
  """
  use TicketServiceWeb, :controller

  import Ecto.Query
  alias TicketService.Repo
  alias TicketService.Orders
  alias TicketService.Orders.Order
  alias TicketService.ETickets

  @doc """
  Search orders by ID, email, or name.

  GET /api/orders/search?q=...&event_id=...
  """
  def search(conn, params) do
    query = Map.get(params, "q", "")
    event_id = Map.get(params, "event_id")

    orders =
      Order
      |> maybe_filter_event(event_id)
      |> search_query(query)
      |> order_by([o], desc: o.inserted_at)
      |> limit(50)
      |> Repo.all()
      |> Repo.preload([:event, order_items: :ticket_type])

    json(conn, %{
      data: Enum.map(orders, &format_order_summary/1),
      count: length(orders)
    })
  end

  @doc """
  Get full order detail with tickets, payment, and refund info.

  GET /api/orders/:id
  """
  def show(conn, %{"id" => id}) do
    case Orders.get_order(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Order not found"})

      order ->
        order = Repo.preload(order, [:event, :tickets, order_items: :ticket_type])
        json(conn, %{data: format_order_detail(order)})
    end
  end

  # --- Private ---

  defp maybe_filter_event(query, nil), do: query
  defp maybe_filter_event(query, event_id), do: where(query, [o], o.event_id == ^event_id)

  defp search_query(query, ""), do: query

  defp search_query(query, search_term) do
    term = "%#{search_term}%"

    # Search by order ID prefix, session_id, or checkout_token
    query
    |> where([o],
      ilike(o.session_id, ^term) or
        ilike(o.checkout_token, ^term) or
        ilike(type(o.id, :string), ^term)
    )
  end

  defp format_order_summary(order) do
    %{
      id: order.id,
      session_id: order.session_id,
      event_id: order.event_id,
      event_title: order.event && order.event.title,
      status: order.status,
      total: order.total,
      item_count: length(order.order_items),
      payment_method: order.payment_method,
      created_at: order.inserted_at
    }
  end

  defp format_order_detail(order) do
    tickets = Map.get(order, :tickets, [])

    %{
      id: order.id,
      session_id: order.session_id,
      status: order.status,
      event: %{
        id: order.event.id,
        title: order.event.title,
        starts_at: order.event.starts_at
      },
      pricing: %{
        subtotal: order.subtotal,
        platform_fee: order.platform_fee,
        processing_fee: order.processing_fee,
        discount_amount: order.discount_amount,
        total: order.total
      },
      payment: %{
        method: order.payment_method,
        stripe_payment_intent_id: order.stripe_payment_intent_id,
        stripe_refund_id: order.stripe_refund_id,
        refund_amount: order.refund_amount,
        refund_reason: order.refund_reason,
        refunded_at: order.refunded_at
      },
      items: Enum.map(order.order_items, fn item ->
        %{
          id: item.id,
          ticket_type: item.ticket_type && item.ticket_type.name,
          quantity: item.quantity,
          unit_price: item.unit_price,
          seat_ids: item.seat_ids
        }
      end),
      tickets: Enum.map(tickets, fn t ->
        %{
          id: t.id,
          token: t.token,
          status: t.status,
          holder_email: t.holder_email,
          holder_name: t.holder_name,
          scanned_at: t.scanned_at,
          emailed_at: t.emailed_at
        }
      end),
      checkout_token: order.checkout_token,
      created_at: order.inserted_at,
      updated_at: order.updated_at
    }
  end
end
