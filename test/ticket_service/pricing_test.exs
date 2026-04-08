defmodule TicketService.PricingTest do
  use ExUnit.Case, async: true

  alias TicketService.Pricing

  describe "calculate/1" do
    test "calculates fees for a single item" do
      items = [%{unit_price: Decimal.new("50.00"), quantity: 2}]
      result = Pricing.calculate(items)

      # subtotal = 50 * 2 = 100.00
      assert Decimal.equal?(result.subtotal, Decimal.new("100.00"))
      assert result.total_tickets == 2

      # platform fee = 100 * 0.025 + 0.50 * 2 = 2.50 + 1.00 = 3.50
      assert Decimal.equal?(result.platform_fee, Decimal.new("3.50"))

      # processing fee = (100 + 3.50) * 0.029 + 0.30 = 3.0015 + 0.30 = 3.3015 -> 3.30
      assert Decimal.equal?(result.processing_fee, Decimal.new("3.30"))

      # total = 100 + 3.50 + 3.30 = 106.80
      assert Decimal.equal?(result.total, Decimal.new("106.80"))
    end

    test "calculates fees for multiple items" do
      items = [
        %{unit_price: Decimal.new("75.00"), quantity: 1},
        %{unit_price: Decimal.new("25.00"), quantity: 3}
      ]

      result = Pricing.calculate(items)

      # subtotal = 75 + 75 = 150.00
      assert Decimal.equal?(result.subtotal, Decimal.new("150.00"))
      assert result.total_tickets == 4

      # platform fee = 150 * 0.025 + 0.50 * 4 = 3.75 + 2.00 = 5.75
      assert Decimal.equal?(result.platform_fee, Decimal.new("5.75"))
    end

    test "handles empty list" do
      result = Pricing.calculate([])

      assert Decimal.equal?(result.subtotal, Decimal.new(0))
      assert result.total_tickets == 0
      assert Decimal.equal?(result.platform_fee, Decimal.new("0.00"))
      # Processing fee has a flat $0.30 component even with zero subtotal
      assert Decimal.equal?(result.processing_fee, Decimal.new("0.30"))
      assert Decimal.equal?(result.total, Decimal.new("0.30"))
    end

    test "handles single free ticket" do
      items = [%{unit_price: Decimal.new("0.00"), quantity: 1}]
      result = Pricing.calculate(items)

      assert Decimal.equal?(result.subtotal, Decimal.new("0.00"))
      # platform fee = 0 * 0.025 + 0.50 * 1 = 0.50
      assert Decimal.equal?(result.platform_fee, Decimal.new("0.50"))
      # processing fee = (0 + 0.50) * 0.029 + 0.30 = 0.0145 + 0.30 = 0.3145 -> 0.31
      assert Decimal.equal?(result.processing_fee, Decimal.new("0.31"))
    end

    test "rounds to two decimal places" do
      # Use a price that creates non-round fees
      items = [%{unit_price: Decimal.new("33.33"), quantity: 3}]
      result = Pricing.calculate(items)

      # All values should be rounded to 2 decimal places
      assert Decimal.scale(result.subtotal) <= 2
      assert Decimal.scale(result.platform_fee) <= 2
      assert Decimal.scale(result.processing_fee) <= 2
      assert Decimal.scale(result.total) <= 2
    end
  end
end
