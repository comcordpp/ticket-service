defmodule TicketService.Pricing.FeeCalculatorTest do
  use TicketService.DataCase, async: true

  alias TicketService.Pricing.FeeCalculator
  alias TicketService.Pricing.FeeConfig
  alias TicketService.Repo

  setup do
    {:ok, venue} =
      %TicketService.Venues.Venue{}
      |> TicketService.Venues.Venue.changeset(%{name: "Test Arena", location: "NYC", capacity: 1000})
      |> Repo.insert()

    {:ok, event} =
      %TicketService.Events.Event{}
      |> TicketService.Events.Event.changeset(%{
        title: "Test Concert",
        description: "A test",
        category: "music",
        status: "published",
        starts_at: DateTime.add(DateTime.utc_now(), 86400, :second),
        ends_at: DateTime.add(DateTime.utc_now(), 90000, :second),
        venue_id: venue.id
      })
      |> Repo.insert()

    %{event: event}
  end

  describe "calculate/2 with default fees" do
    test "calculates correct breakdown for single item", %{event: event} do
      items = [%{ticket_type_id: nil, unit_price: Decimal.new("50.00"), quantity: 2}]
      result = FeeCalculator.calculate(items, event.id)

      # subtotal: 50 * 2 = 10000 cents
      assert result.subtotal_cents == 10000
      # service fee: 10000 * 0.10 = 1000 cents
      assert result.service_fee_cents == 1000
      # platform fee: 150 flat + 0% = 150 cents
      assert result.platform_fee_cents == 150
      # tax: 0%
      assert result.tax_cents == 0
      # total: 10000 + 1000 + 150 = 11150 cents
      assert result.total_cents == 11150
      assert result.currency == "USD"
    end

    test "is deterministic — same input always same output", %{event: event} do
      items = [%{ticket_type_id: nil, unit_price: Decimal.new("75.00"), quantity: 3}]
      result1 = FeeCalculator.calculate(items, event.id)
      result2 = FeeCalculator.calculate(items, event.id)

      assert result1 == result2
    end

    test "handles zero-price tickets", %{event: event} do
      items = [%{ticket_type_id: nil, unit_price: Decimal.new("0"), quantity: 2}]
      result = FeeCalculator.calculate(items, event.id)

      assert result.subtotal_cents == 0
      assert result.service_fee_cents == 0
      assert result.platform_fee_cents == 150
      assert result.tax_cents == 0
      assert result.total_cents == 150
    end

    test "returns per-item breakdown", %{event: event} do
      items = [
        %{ticket_type_id: "a", unit_price: Decimal.new("100.00"), quantity: 1},
        %{ticket_type_id: "b", unit_price: Decimal.new("50.00"), quantity: 2}
      ]

      result = FeeCalculator.calculate(items, event.id)

      assert length(result.items) == 2

      [item_a, item_b] = result.items
      assert item_a.base_price_cents == 10000
      assert item_a.line_total_cents == 10000
      assert item_a.service_fee_cents == 1000

      assert item_b.base_price_cents == 5000
      assert item_b.line_total_cents == 10000
      assert item_b.service_fee_cents == 1000
    end
  end

  describe "calculate/2 with custom fee config" do
    test "uses event-specific fee configuration", %{event: event} do
      Repo.insert!(%FeeConfig{
        event_id: event.id,
        service_fee_pct: Decimal.new("15.0"),
        platform_fee_flat: 200,
        platform_fee_pct: Decimal.new("2.0"),
        tax_rate: Decimal.new("8.5")
      })

      items = [%{ticket_type_id: nil, unit_price: Decimal.new("100.00"), quantity: 1}]
      result = FeeCalculator.calculate(items, event.id)

      # subtotal: 10000 cents
      assert result.subtotal_cents == 10000
      # service fee: 10000 * 0.15 = 1500
      assert result.service_fee_cents == 1500
      # platform fee: 200 flat + 10000 * 0.02 = 200 + 200 = 400
      assert result.platform_fee_cents == 400
      # tax: (10000 + 1500 + 400) * 0.085 = 11900 * 0.085 = 1011.5 -> 1012
      assert result.tax_cents == 1012
      # total: 10000 + 1500 + 400 + 1012 = 12912
      assert result.total_cents == 12912

      assert result.fee_config.service_fee_pct == Decimal.new("15.0")
      assert result.fee_config.tax_rate == Decimal.new("8.5")
    end
  end

  describe "get_fee_config/1" do
    test "returns defaults when no config exists", %{event: event} do
      config = FeeCalculator.get_fee_config(event.id)

      assert config.service_fee_pct == Decimal.new("10.0")
      assert config.platform_fee_flat == 150
      assert config.platform_fee_pct == Decimal.new("0.0")
      assert config.tax_rate == Decimal.new("0.0")
    end

    test "returns event-specific config when it exists", %{event: event} do
      Repo.insert!(%FeeConfig{
        event_id: event.id,
        service_fee_pct: Decimal.new("5.0"),
        platform_fee_flat: 100,
        platform_fee_pct: Decimal.new("1.0"),
        tax_rate: Decimal.new("7.0")
      })

      config = FeeCalculator.get_fee_config(event.id)

      assert config.service_fee_pct == Decimal.new("5.0")
      assert config.platform_fee_flat == 100
      assert config.tax_rate == Decimal.new("7.0")
    end
  end

  describe "upsert_fee_config/2" do
    test "creates new config", %{event: event} do
      {:ok, config} =
        FeeCalculator.upsert_fee_config(event.id, %{
          service_fee_pct: Decimal.new("12.0"),
          platform_fee_flat: 200
        })

      assert config.service_fee_pct == Decimal.new("12.0")
      assert config.platform_fee_flat == 200
      assert config.event_id == event.id
    end

    test "updates existing config", %{event: event} do
      {:ok, _} =
        FeeCalculator.upsert_fee_config(event.id, %{service_fee_pct: Decimal.new("10.0")})

      {:ok, updated} =
        FeeCalculator.upsert_fee_config(event.id, %{service_fee_pct: Decimal.new("15.0")})

      assert updated.service_fee_pct == Decimal.new("15.0")
    end
  end
end
