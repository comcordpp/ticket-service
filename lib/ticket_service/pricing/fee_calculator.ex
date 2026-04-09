defmodule TicketService.Pricing.FeeCalculator do
  @moduledoc """
  Centralized fee calculation engine with per-event configurable fees.

  Computes an itemized breakdown of all fees (service fee, platform fee, tax)
  for a set of line items. All monetary values are in cents (integers) to avoid
  floating-point issues.

  Default fee structure (when no event-specific config exists):
  - Service fee: 10% of subtotal
  - Platform fee: $1.50 flat (150 cents)
  - Tax: 0%
  """

  import Ecto.Query
  alias TicketService.Repo
  alias TicketService.Pricing.FeeConfig

  @default_service_fee_pct Decimal.new("10.0")
  @default_platform_fee_flat 150
  @default_platform_fee_pct Decimal.new("0.0")
  @default_tax_rate Decimal.new("0.0")

  @doc """
  Calculate an itemized fee breakdown for the given line items and event.

  Each line item must have `:unit_price` (Decimal, in dollars) and `:quantity` (integer).

  Returns a map with all values in cents (integers):
    - :items — per-item breakdown with base_price_cents, service_fee_cents, line_total_cents
    - :subtotal_cents — sum of base prices
    - :service_fee_cents — percentage-based, configurable per event
    - :platform_fee_cents — flat + percentage, configurable per event
    - :tax_cents — based on venue/event tax rate
    - :total_cents — grand total
    - :currency — "USD"
    - :fee_config — the fee rates used for this calculation
  """
  def calculate(line_items, event_id) do
    config = get_fee_config(event_id)

    service_pct = Decimal.div(config.service_fee_pct, Decimal.new(100))
    platform_pct = Decimal.div(config.platform_fee_pct, Decimal.new(100))
    tax_pct = Decimal.div(config.tax_rate, Decimal.new(100))

    items =
      Enum.map(line_items, fn item ->
        unit_price_cents = decimal_to_cents(item.unit_price)
        line_base_cents = unit_price_cents * item.quantity

        line_service_cents =
          Decimal.mult(Decimal.new(line_base_cents), service_pct)
          |> Decimal.round(0, :half_up)
          |> Decimal.to_integer()

        %{
          ticket_type_id: Map.get(item, :ticket_type_id),
          quantity: item.quantity,
          base_price_cents: unit_price_cents,
          line_total_cents: line_base_cents,
          service_fee_cents: line_service_cents
        }
      end)

    subtotal_cents = Enum.reduce(items, 0, fn i, acc -> acc + i.line_total_cents end)
    service_fee_cents = Enum.reduce(items, 0, fn i, acc -> acc + i.service_fee_cents end)

    platform_fee_pct_cents =
      Decimal.mult(Decimal.new(subtotal_cents), platform_pct)
      |> Decimal.round(0, :half_up)
      |> Decimal.to_integer()

    platform_fee_cents = config.platform_fee_flat + platform_fee_pct_cents

    taxable_amount = subtotal_cents + service_fee_cents + platform_fee_cents

    tax_cents =
      Decimal.mult(Decimal.new(taxable_amount), tax_pct)
      |> Decimal.round(0, :half_up)
      |> Decimal.to_integer()

    total_cents = subtotal_cents + service_fee_cents + platform_fee_cents + tax_cents

    %{
      items: items,
      subtotal_cents: subtotal_cents,
      service_fee_cents: service_fee_cents,
      platform_fee_cents: platform_fee_cents,
      tax_cents: tax_cents,
      total_cents: total_cents,
      currency: "USD",
      fee_config: %{
        service_fee_pct: config.service_fee_pct,
        platform_fee_flat_cents: config.platform_fee_flat,
        platform_fee_pct: config.platform_fee_pct,
        tax_rate: config.tax_rate
      }
    }
  end

  @doc """
  Get the fee configuration for an event, falling back to defaults.
  """
  def get_fee_config(event_id) do
    case Repo.one(from(fc in FeeConfig, where: fc.event_id == ^event_id)) do
      nil ->
        %{
          service_fee_pct: @default_service_fee_pct,
          platform_fee_flat: @default_platform_fee_flat,
          platform_fee_pct: @default_platform_fee_pct,
          tax_rate: @default_tax_rate
        }

      fc ->
        %{
          service_fee_pct: fc.service_fee_pct,
          platform_fee_flat: fc.platform_fee_flat,
          platform_fee_pct: fc.platform_fee_pct,
          tax_rate: fc.tax_rate
        }
    end
  end

  @doc """
  Create or update fee configuration for an event.
  """
  def upsert_fee_config(event_id, attrs) do
    case Repo.one(from(fc in FeeConfig, where: fc.event_id == ^event_id)) do
      nil ->
        %FeeConfig{}
        |> FeeConfig.changeset(Map.put(attrs, :event_id, event_id))
        |> Repo.insert()

      existing ->
        existing
        |> FeeConfig.changeset(attrs)
        |> Repo.update()
    end
  end

  defp decimal_to_cents(%Decimal{} = d) do
    d
    |> Decimal.mult(Decimal.new(100))
    |> Decimal.round(0, :half_up)
    |> Decimal.to_integer()
  end

  defp decimal_to_cents(val) when is_number(val) do
    round(val * 100)
  end
end
