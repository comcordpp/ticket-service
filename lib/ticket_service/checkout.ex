defmodule TicketService.Checkout do
  @moduledoc """
  Checkout context — enriches cart data with pricing details and manages
  the transition from cart review to payment.
  """
  import Ecto.Query

  alias TicketService.Repo
  alias TicketService.Carts
  alias TicketService.Tickets.TicketType
  alias TicketService.Seating.Seat
  alias TicketService.Pricing

  @default_ttl_ms :timer.minutes(10)

  @doc """
  Get cart with enriched line items including ticket type details, section info,
  seat details, unit prices, and a full fee breakdown from the Pricing module.
  """
  def get_cart_with_details(session_id) do
    with {:ok, cart} <- Carts.get_cart(session_id) do
      enrich_cart(cart)
    end
  end

  @doc """
  Transition the cart to checkout state.

  Validates:
  - Cart exists and is not expired
  - All held seats are still in "held" status
  - Inventory is still available for all items

  Returns {:ok, checkout_session} with a checkout token and fee breakdown,
  or {:error, reason}.
  """
  def checkout(session_id) do
    with {:ok, cart} <- Carts.get_cart(session_id),
         :ok <- validate_cart_for_checkout(cart),
         {:ok, enriched} <- enrich_cart(cart) do
      checkout_token = generate_checkout_token()

      checkout_session = %{
        checkout_token: checkout_token,
        session_id: session_id,
        line_items: enriched.line_items,
        fees: enriched.fees,
        expires_at: DateTime.add(DateTime.utc_now(), 900, :second),
        status: "pending_payment"
      }

      {:ok, checkout_session}
    end
  end

  defp validate_cart_for_checkout(%{items: []}) do
    {:error, :cart_empty}
  end

  defp validate_cart_for_checkout(%{items: items}) do
    ticket_type_ids = Enum.map(items, & &1.ticket_type_id)
    seat_ids = items |> Enum.flat_map(& &1.seat_ids)

    with :ok <- validate_inventory(ticket_type_ids),
         :ok <- validate_seats_held(seat_ids) do
      :ok
    end
  end

  defp validate_inventory(ticket_type_ids) do
    available_count =
      from(tt in TicketType,
        where: tt.id in ^ticket_type_ids,
        where: tt.quantity > tt.sold_count
      )
      |> Repo.aggregate(:count)

    if available_count == length(ticket_type_ids) do
      :ok
    else
      {:error, :insufficient_inventory}
    end
  end

  defp validate_seats_held([]), do: :ok

  defp validate_seats_held(seat_ids) do
    held_count =
      from(s in Seat,
        where: s.id in ^seat_ids,
        where: s.status == "held"
      )
      |> Repo.aggregate(:count)

    if held_count == length(seat_ids) do
      :ok
    else
      {:error, :seats_no_longer_held}
    end
  end

  defp enrich_cart(cart) do
    ticket_type_ids = Enum.map(cart.items, & &1.ticket_type_id)
    seat_ids = cart.items |> Enum.flat_map(& &1.seat_ids)

    ticket_types =
      from(tt in TicketType,
        where: tt.id in ^ticket_type_ids
      )
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    seats =
      if seat_ids != [] do
        from(s in Seat,
          where: s.id in ^seat_ids,
          preload: [:section]
        )
        |> Repo.all()
        |> Map.new(&{&1.id, &1})
      else
        %{}
      end

    line_items =
      Enum.map(cart.items, fn item ->
        tt = Map.get(ticket_types, item.ticket_type_id)

        item_seats =
          item.seat_ids
          |> Enum.map(&Map.get(seats, &1))
          |> Enum.reject(&is_nil/1)

        section =
          case item_seats do
            [first | _] -> first.section
            _ -> nil
          end

        %{
          ticket_type_id: item.ticket_type_id,
          ticket_type_name: tt && tt.name,
          event_id: tt && tt.event_id,
          quantity: item.quantity,
          unit_price: tt && tt.price,
          section: section && %{id: section.id, name: section.name, type: section.type},
          seats:
            Enum.map(item_seats, fn s ->
              %{id: s.id, row_label: s.row_label, seat_number: s.seat_number}
            end)
        }
      end)

    pricing_items =
      Enum.map(line_items, fn li ->
        %{unit_price: li.unit_price || Decimal.new(0), quantity: li.quantity}
      end)

    fees = Pricing.calculate(pricing_items)
    ttl_remaining_ms = cart_ttl_remaining(cart)

    {:ok,
     %{
       session_id: cart.session_id,
       line_items: line_items,
       item_count: length(line_items),
       total_tickets: fees.total_tickets,
       fees: fees,
       ttl_remaining_seconds: max(div(ttl_remaining_ms, 1000), 0),
       created_at: cart.created_at,
       last_activity_at: cart.last_activity_at
     }}
  end

  defp cart_ttl_remaining(cart) do
    ttl_ms = @default_ttl_ms
    elapsed = DateTime.diff(DateTime.utc_now(), cart.last_activity_at, :millisecond)
    ttl_ms - elapsed
  end

  defp generate_checkout_token do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end
end
