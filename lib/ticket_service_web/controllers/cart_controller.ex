defmodule TicketServiceWeb.CartController do
  use TicketServiceWeb, :controller

  alias TicketService.Carts

  def show(conn, %{"session_id" => session_id}) do
    case Carts.get_or_create_cart(session_id) do
      {:ok, cart} -> json(conn, %{data: cart})
      {:error, reason} -> error_response(conn, reason)
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

  defp error_response(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: to_string(reason)})
  end
end
