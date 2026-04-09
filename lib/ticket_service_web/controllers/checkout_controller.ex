defmodule TicketServiceWeb.CheckoutController do
  use TicketServiceWeb, :controller

  alias TicketService.Orders
  alias TicketService.Carts
  alias TicketService.Pricing
  alias TicketService.Repo

  @doc "Review cart with full pricing breakdown before checkout."
  def review(conn, %{"session_id" => session_id} = params) do
    promo_code = Map.get(params, "promo_code")

    with {:ok, cart} <- Carts.get_cart(session_id),
         {:ok, details} <- build_review(cart, promo_code) do
      json(conn, %{data: details})
    else
      {:error, :cart_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Cart not found"})

      {:error, :cart_empty} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Cart is empty"})

      {:error, {:invalid_promo, reason}} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Invalid promo code: #{reason}"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})
    end
  end

  @doc "Create an order from the cart and return a checkout token."
  def create(conn, %{"session_id" => session_id} = params) do
    opts =
      case Map.get(params, "promo_code") do
        nil -> []
        code -> [promo_code: code]
      end

    case Orders.checkout(session_id, opts) do
      {:ok, order} ->
        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            order_id: order.id,
            checkout_token: order.checkout_token,
            checkout_expires_at: order.checkout_expires_at,
            subtotal: order.subtotal,
            platform_fee: order.platform_fee,
            processing_fee: order.processing_fee,
            discount_amount: order.discount_amount,
            total: order.total,
            items: Enum.map(order.order_items, &format_order_item/1)
          }
        })

      {:error, :cart_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Cart not found"})

      {:error, :cart_empty} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Cart is empty"})

      {:error, :mixed_events_in_cart} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Cart contains tickets from multiple events"})

      {:error, {:invalid_promo, reason}} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Invalid promo code: #{reason}"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})
    end
  end

  @doc "Get order details by checkout token."
  def show(conn, %{"token" => token}) do
    case Orders.get_order_by_token(token) do
      {:ok, order} ->
        json(conn, %{data: format_order(order)})

      {:error, :invalid_or_expired_token} ->
        conn |> put_status(:not_found) |> json(%{error: "Invalid or expired checkout token"})
    end
  end

  @doc "Confirm an order (simulates payment success for dev/testing)."
  def confirm(conn, %{"token" => token} = params) do
    opts = [
      email: Map.get(params, "email"),
      name: Map.get(params, "name")
    ]

    with {:ok, order} <- Orders.get_order_by_token(token),
         {:ok, confirmed} <- Orders.confirm_order(order, opts) do
      confirmed = Repo.preload(confirmed, order_items: :ticket_type)
      json(conn, %{data: format_order(confirmed)})
    else
      {:error, :invalid_or_expired_token} ->
        conn |> put_status(:not_found) |> json(%{error: "Invalid or expired checkout token"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})
    end
  end

  # --- Private ---

  defp build_review(cart, promo_code) do
    if cart.items == [] do
      {:error, :cart_empty}
    else
      ticket_types =
        Enum.map(cart.items, fn item ->
          tt = TicketService.Repo.get!(TicketService.Tickets.TicketType, item.ticket_type_id)
          %{ticket_type: tt, quantity: item.quantity, seat_ids: item.seat_ids}
        end)

      event_ids = ticket_types |> Enum.map(& &1.ticket_type.event_id) |> Enum.uniq()

      if length(event_ids) != 1 do
        {:error, :mixed_events_in_cart}
      else
        event_id = hd(event_ids)

        promo_result =
          if promo_code do
            TicketService.Tickets.validate_promo_code(event_id, promo_code)
          else
            {:ok, nil}
          end

        case promo_result do
          {:ok, promo} ->
            line_items = Enum.map(ticket_types, fn item ->
              %{unit_price: item.ticket_type.price, quantity: item.quantity}
            end)

            pricing = Pricing.calculate(line_items)

            discount_amount =
              case promo do
                nil -> Decimal.new(0)
                %{discount_type: "percentage", discount_value: pct} ->
                  Decimal.mult(pricing.subtotal, Decimal.div(pct, Decimal.new(100))) |> Decimal.round(2)
                %{discount_type: "fixed", discount_value: amt} ->
                  Decimal.min(amt, pricing.subtotal)
              end

            total_after_discount =
              pricing.total
              |> Decimal.sub(discount_amount)
              |> Decimal.max(Decimal.new(0))

            {:ok, %{
              items: Enum.map(ticket_types, fn item ->
                %{
                  ticket_type_id: item.ticket_type.id,
                  name: item.ticket_type.name,
                  unit_price: item.ticket_type.price,
                  quantity: item.quantity,
                  seat_ids: item.seat_ids,
                  line_total: Decimal.mult(item.ticket_type.price, Decimal.new(item.quantity))
                }
              end),
              subtotal: pricing.subtotal,
              platform_fee: pricing.platform_fee,
              processing_fee: pricing.processing_fee,
              discount_amount: discount_amount,
              total: total_after_discount,
              promo_applied: promo != nil
            }}

          {:error, reason} ->
            {:error, {:invalid_promo, reason}}
        end
      end
    end
  end

  defp format_order(order) do
    %{
      id: order.id,
      session_id: order.session_id,
      status: order.status,
      event_id: order.event_id,
      subtotal: order.subtotal,
      platform_fee: order.platform_fee,
      processing_fee: order.processing_fee,
      discount_amount: order.discount_amount,
      total: order.total,
      checkout_token: order.checkout_token,
      checkout_expires_at: order.checkout_expires_at,
      items: Enum.map(order.order_items, &format_order_item/1),
      created_at: order.inserted_at
    }
  end

  defp format_order_item(item) do
    %{
      id: item.id,
      ticket_type_id: item.ticket_type_id,
      quantity: item.quantity,
      unit_price: item.unit_price,
      seat_ids: item.seat_ids
    }
  end

end
