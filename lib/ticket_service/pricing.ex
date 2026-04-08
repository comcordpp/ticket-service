defmodule TicketService.Pricing do
  @moduledoc """
  Pricing engine — calculates fees for ticket purchases.

  Fee structure:
  - Platform fee: 2.5% of subtotal + $0.50 per ticket
  - Processing fee: 2.9% of (subtotal + platform_fee) + $0.30
  """

  @platform_rate Decimal.new("0.025")
  @platform_per_ticket Decimal.new("0.50")
  @processing_rate Decimal.new("0.029")
  @processing_flat Decimal.new("0.30")

  @doc """
  Calculate pricing for a list of line items.

  Each line item is a map with `:unit_price` (Decimal) and `:quantity` (integer).

  Returns a map with :subtotal, :total_tickets, :platform_fee, :processing_fee, :total.
  """
  def calculate(line_items) do
    subtotal =
      Enum.reduce(line_items, Decimal.new(0), fn item, acc ->
        Decimal.add(acc, Decimal.mult(item.unit_price, Decimal.new(item.quantity)))
      end)

    total_tickets =
      Enum.reduce(line_items, 0, fn item, acc -> acc + item.quantity end)

    platform_fee =
      Decimal.add(
        Decimal.mult(subtotal, @platform_rate),
        Decimal.mult(@platform_per_ticket, Decimal.new(total_tickets))
      )
      |> Decimal.round(2)

    processing_fee =
      Decimal.add(
        Decimal.mult(Decimal.add(subtotal, platform_fee), @processing_rate),
        @processing_flat
      )
      |> Decimal.round(2)

    total =
      subtotal
      |> Decimal.add(platform_fee)
      |> Decimal.add(processing_fee)
      |> Decimal.round(2)

    %{
      subtotal: subtotal,
      total_tickets: total_tickets,
      platform_fee: platform_fee,
      processing_fee: processing_fee,
      total: total
    }
  end
end
