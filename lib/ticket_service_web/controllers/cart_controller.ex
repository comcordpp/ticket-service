defmodule TicketServiceWeb.CartController do
  use TicketServiceWeb, :controller

  alias TicketService.Carts
  alias TicketService.Checkout

  def show(conn, %{"session_id" => session_id}) do
    case Checkout.get_cart_with_details(session_id) do
      {:ok, cart} ->
        json(conn, %{data: cart_json(cart)})

      {:error, :cart_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Cart not found"})

      {:error, reason} ->
        error_response(conn, reason)
    end
  end

  def add_item(conn, %{"session_id" => session_id, "ticket_type_id" => ticket_type_id} = params) do
    quantity = Map.get(params, "quantity", 1)
    seat_ids = Map.get(params, "seat_ids", [])

    case Carts.add_item(session_id, ticket_type_id, quantity, seat_ids: seat_ids) do
      {:ok, cart} ->
        json(conn, %{data: cart})

      {:error, :insufficient_inventory} ->
        conn |> put_status(:conflict) |> json(%{error: "Insufficient inventory"})

      {:error, :seats_unavailable} ->
        conn |> put_status(:conflict) |> json(%{error: "One or more seats are unavailable"})

      {:error, :cart_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Cart not found"})

      {:error, reason} ->
        error_response(conn, reason)
    end
  end

  def remove_item(conn, %{"session_id" => session_id, "ticket_type_id" => ticket_type_id}) do
    case Carts.remove_item(session_id, ticket_type_id) do
      {:ok, cart} ->
        json(conn, %{data: cart})

      {:error, :item_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Item not found in cart"})

      {:error, :cart_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Cart not found"})

      {:error, reason} ->
        error_response(conn, reason)
    end
  end

  def update_item(conn, %{"session_id" => session_id, "ticket_type_id" => ticket_type_id, "quantity" => quantity}) do
    case Carts.update_quantity(session_id, ticket_type_id, quantity) do
      {:ok, cart} ->
        json(conn, %{data: cart})

      {:error, :insufficient_inventory} ->
        conn |> put_status(:conflict) |> json(%{error: "Insufficient inventory"})

      {:error, :item_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Item not found in cart"})

      {:error, :cart_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Cart not found"})

      {:error, reason} ->
        error_response(conn, reason)
    end
  end

  def clear(conn, %{"session_id" => session_id}) do
    case Carts.clear_cart(session_id) do
      {:ok, cart} ->
        json(conn, %{data: cart})

      {:error, :cart_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Cart not found"})

      {:error, reason} ->
        error_response(conn, reason)
    end
  end

  defp cart_json(cart) do
    %{
      session_id: cart.session_id,
      line_items: Enum.map(cart.line_items, &line_item_json/1),
      item_count: cart.item_count,
      total_tickets: cart.total_tickets,
      fees: fees_json(cart.fees),
      ttl_remaining_seconds: cart.ttl_remaining_seconds,
      created_at: cart.created_at,
      last_activity_at: cart.last_activity_at
    }
  end

  defp line_item_json(item) do
    base = %{
      ticket_type_id: item.ticket_type_id,
      ticket_type_name: item.ticket_type_name,
      quantity: item.quantity,
      unit_price: item.unit_price
    }

    base = if item[:section], do: Map.put(base, :section, item.section), else: base
    if item[:seats] != nil and item.seats != [], do: Map.put(base, :seats, item.seats), else: base
  end

  defp fees_json(fees) do
    %{
      subtotal: fees.subtotal,
      total_tickets: fees.total_tickets,
      platform_fee: fees.platform_fee,
      processing_fee: fees.processing_fee,
      total: fees.total
    }
  end

  defp error_response(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: to_string(reason)})
  end
end
