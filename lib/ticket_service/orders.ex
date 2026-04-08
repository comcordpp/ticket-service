defmodule TicketService.Orders do
  @moduledoc """
  The Orders context — manages checkout flow, order creation, and order lifecycle.
  """
  import Ecto.Query
  alias TicketService.Repo
  alias TicketService.Orders.{Order, OrderItem}
  alias TicketService.Tickets.TicketType
  alias TicketService.Tickets
  alias TicketService.Carts
  alias TicketService.Pricing
  alias TicketService.Seating.Seat

  @checkout_token_ttl_minutes 15

  @doc """
  Creates an order from the current cart contents.

  1. Validates cart is non-empty and all inventory is still held
  2. Resolves ticket prices and computes pricing breakdown
  3. Optionally applies a promo code discount
  4. Creates the Order + OrderItems in a transaction
  5. Generates a checkout token valid for 15 minutes
  """
  def checkout(session_id, opts \\ []) do
    promo_code = Keyword.get(opts, :promo_code)

    with {:ok, cart} <- Carts.get_cart(session_id),
         :ok <- validate_cart_non_empty(cart),
         {:ok, line_items} <- resolve_line_items(cart),
         {:ok, event_id} <- resolve_event_id(line_items),
         {:ok, promo} <- resolve_promo(event_id, promo_code),
         pricing <- calculate_pricing(line_items, promo) do
      create_order(session_id, event_id, cart, line_items, pricing, promo)
    end
  end

  @doc "Get an order by ID with items preloaded."
  def get_order(id) do
    Order
    |> Repo.get(id)
    |> Repo.preload(order_items: :ticket_type)
  end

  @doc "Get an order by checkout token."
  def get_order_by_token(token) do
    Order
    |> where([o], o.checkout_token == ^token and o.status == "pending")
    |> where([o], o.checkout_expires_at > ^DateTime.utc_now())
    |> Repo.one()
    |> case do
      nil -> {:error, :invalid_or_expired_token}
      order -> {:ok, Repo.preload(order, order_items: :ticket_type)}
    end
  end

  @doc "Confirm an order (after successful payment)."
  def confirm_order(%Order{} = order) do
    Repo.transaction(fn ->
      # Mark order confirmed
      {:ok, confirmed} =
        order
        |> Order.changeset(%{status: "confirmed"})
        |> Repo.update()

      # Mark seats as sold
      order = Repo.preload(order, :order_items)

      seat_ids =
        order.order_items
        |> Enum.flat_map(& &1.seat_ids)
        |> Enum.reject(&is_nil/1)

      if seat_ids != [] do
        from(s in Seat, where: s.id in ^seat_ids and s.status == "held")
        |> Repo.update_all(set: [status: "sold", updated_at: DateTime.utc_now() |> DateTime.truncate(:second)])
      end

      # Increment promo code used_count if applicable
      if confirmed.promo_code_id do
        from(pc in TicketService.Tickets.PromoCode,
          where: pc.id == ^confirmed.promo_code_id
        )
        |> Repo.update_all(inc: [used_count: 1])
      end

      confirmed
    end)
  end

  @doc "Cancel an order and release inventory."
  def cancel_order(%Order{} = order) do
    order = Repo.preload(order, :order_items)

    Repo.transaction(fn ->
      {:ok, cancelled} =
        order
        |> Order.changeset(%{status: "cancelled"})
        |> Repo.update()

      # Release held inventory
      Enum.each(order.order_items, fn item ->
        Carts.release_inventory_on_expiry(item.ticket_type_id, item.quantity, item.seat_ids)
      end)

      cancelled
    end)
  end

  @doc "List orders for an event."
  def list_orders_for_event(event_id, filters \\ %{}) do
    Order
    |> where([o], o.event_id == ^event_id)
    |> apply_order_filters(filters)
    |> order_by([o], desc: o.inserted_at)
    |> Repo.all()
    |> Repo.preload(:order_items)
  end

  @doc "Check if an event has any confirmed orders (sales)."
  def event_has_sales?(event_id) do
    Order
    |> where([o], o.event_id == ^event_id and o.status == "confirmed")
    |> Repo.exists?()
  end

  # --- Private ---

  defp validate_cart_non_empty(%{items: []}), do: {:error, :cart_empty}
  defp validate_cart_non_empty(%{items: items}) when length(items) > 0, do: :ok
  defp validate_cart_non_empty(_), do: {:error, :cart_empty}

  defp resolve_line_items(cart) do
    items =
      Enum.map(cart.items, fn item ->
        case Repo.get(TicketType, item.ticket_type_id) do
          nil -> {:error, :ticket_type_not_found}
          tt -> {:ok, %{ticket_type: tt, quantity: item.quantity, seat_ids: item.seat_ids}}
        end
      end)

    errors = Enum.filter(items, &match?({:error, _}, &1))

    if errors == [] do
      {:ok, Enum.map(items, fn {:ok, item} -> item end)}
    else
      List.first(errors)
    end
  end

  defp resolve_event_id(line_items) do
    event_ids =
      line_items
      |> Enum.map(& &1.ticket_type.event_id)
      |> Enum.uniq()

    case event_ids do
      [event_id] -> {:ok, event_id}
      _ -> {:error, :mixed_events_in_cart}
    end
  end

  defp resolve_promo(_event_id, nil), do: {:ok, nil}

  defp resolve_promo(event_id, code) do
    case Tickets.validate_promo_code(event_id, code) do
      {:ok, promo} -> {:ok, promo}
      {:error, reason} -> {:error, {:invalid_promo, reason}}
    end
  end

  defp calculate_pricing(line_items, promo) do
    pricing_items =
      Enum.map(line_items, fn item ->
        %{unit_price: item.ticket_type.price, quantity: item.quantity}
      end)

    base_pricing = Pricing.calculate(pricing_items)

    case promo do
      nil ->
        Map.put(base_pricing, :discount_amount, Decimal.new(0))

      %{discount_type: "percentage", discount_value: pct} ->
        discount = Decimal.mult(base_pricing.subtotal, Decimal.div(pct, Decimal.new(100)))
        new_subtotal = Decimal.sub(base_pricing.subtotal, discount)
        recalc = Pricing.calculate([%{unit_price: new_subtotal, quantity: 1}])
        Map.merge(recalc, %{subtotal: base_pricing.subtotal, discount_amount: discount})

      %{discount_type: "fixed", discount_value: amount} ->
        discount = Decimal.min(amount, base_pricing.subtotal)
        new_subtotal = Decimal.sub(base_pricing.subtotal, discount)
        recalc = Pricing.calculate([%{unit_price: new_subtotal, quantity: 1}])
        Map.merge(recalc, %{subtotal: base_pricing.subtotal, discount_amount: discount})
    end
  end

  defp create_order(session_id, event_id, _cart, line_items, pricing, promo) do
    token = generate_checkout_token()
    expires_at = DateTime.add(DateTime.utc_now(), @checkout_token_ttl_minutes * 60, :second) |> DateTime.truncate(:second)

    order_attrs = %{
      session_id: session_id,
      event_id: event_id,
      status: "pending",
      subtotal: pricing.subtotal,
      platform_fee: pricing.platform_fee,
      processing_fee: pricing.processing_fee,
      discount_amount: pricing.discount_amount,
      total: pricing.total,
      checkout_token: token,
      checkout_expires_at: expires_at,
      promo_code_id: promo && promo.id
    }

    Repo.transaction(fn ->
      {:ok, order} =
        %Order{}
        |> Order.changeset(order_attrs)
        |> Repo.insert()

      order_items =
        Enum.map(line_items, fn item ->
          {:ok, oi} =
            %OrderItem{}
            |> OrderItem.changeset(%{
              order_id: order.id,
              ticket_type_id: item.ticket_type.id,
              quantity: item.quantity,
              unit_price: item.ticket_type.price,
              seat_ids: item.seat_ids
            })
            |> Repo.insert()

          oi
        end)

      %{order | order_items: order_items}
    end)
  end

  defp generate_checkout_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end

  defp apply_order_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:status, status}, q -> where(q, [o], o.status == ^status)
      _, q -> q
    end)
  end
end
