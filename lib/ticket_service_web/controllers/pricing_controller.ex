defmodule TicketServiceWeb.PricingController do
  use TicketServiceWeb, :controller

  alias TicketService.Carts
  alias TicketService.Repo
  alias TicketService.Tickets.TicketType
  alias TicketService.Pricing.FeeCalculator

  import Ecto.Query

  @doc """
  GET /api/cart/:session_id/pricing

  Returns an itemized fee breakdown for the cart contents.
  All monetary values are in cents (integers) to avoid floating-point issues.
  Response is idempotent and cacheable — same cart state always produces the same result.
  """
  def show(conn, %{"session_id" => session_id}) do
    with {:ok, cart} <- Carts.get_cart(session_id),
         :ok <- validate_non_empty(cart),
         {:ok, breakdown} <- build_pricing_breakdown(cart) do
      conn
      |> put_resp_header("cache-control", "private, max-age=30")
      |> json(%{data: breakdown})
    else
      {:error, :cart_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Cart not found"})

      {:error, :cart_empty} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Cart is empty"})

      {:error, :mixed_events} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Cart contains tickets from multiple events"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})
    end
  end

  defp validate_non_empty(%{items: []}), do: {:error, :cart_empty}
  defp validate_non_empty(_), do: :ok

  defp build_pricing_breakdown(cart) do
    ticket_type_ids = Enum.map(cart.items, & &1.ticket_type_id)

    ticket_types =
      from(tt in TicketType, where: tt.id in ^ticket_type_ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    event_ids =
      ticket_types
      |> Map.values()
      |> Enum.map(& &1.event_id)
      |> Enum.uniq()

    case event_ids do
      [event_id] ->
        line_items =
          Enum.map(cart.items, fn item ->
            tt = Map.get(ticket_types, item.ticket_type_id)

            %{
              ticket_type_id: item.ticket_type_id,
              unit_price: tt.price,
              quantity: item.quantity
            }
          end)

        breakdown = FeeCalculator.calculate(line_items, event_id)

        items_with_names =
          Enum.map(breakdown.items, fn item ->
            tt = Map.get(ticket_types, item.ticket_type_id)

            %{
              ticket_type_id: item.ticket_type_id,
              ticket_type_name: tt && tt.name,
              quantity: item.quantity,
              base_price_cents: item.base_price_cents,
              service_fee_cents: item.service_fee_cents,
              line_total_cents: item.line_total_cents
            }
          end)

        {:ok,
         %{
           items: items_with_names,
           subtotal_cents: breakdown.subtotal_cents,
           service_fee_cents: breakdown.service_fee_cents,
           platform_fee_cents: breakdown.platform_fee_cents,
           tax_cents: breakdown.tax_cents,
           total_cents: breakdown.total_cents,
           currency: breakdown.currency,
           fee_rates: breakdown.fee_config
         }}

      [] ->
        {:error, :cart_empty}

      _ ->
        {:error, :mixed_events}
    end
  end
end
