defmodule TicketService.PricingTest do
  use ExUnit.Case, async: true

  alias TicketService.Pricing

  describe "calculate/1" do
    test "calculates correct fee breakdown for single item" do
      items = [%{unit_price: Decimal.new("100.00"), quantity: 1}]
      result = Pricing.calculate(items)

      assert result.subtotal == Decimal.new("100.00")
      assert result.total_tickets == 1
      # Platform: 100 * 0.025 + 0.50 * 1 = 2.50 + 0.50 = 3.00
      assert result.platform_fee == Decimal.new("3.00")
      # Processing: (100 + 3) * 0.029 + 0.30 = 2.987 + 0.30 = 3.287 -> 3.29
      assert result.processing_fee == Decimal.new("3.29")
      # Total: 100 + 3 + 3.29 = 106.29
      assert result.total == Decimal.new("106.29")
    end

    test "calculates correct fee for multiple tickets" do
      items = [%{unit_price: Decimal.new("50.00"), quantity: 3}]
      result = Pricing.calculate(items)

      assert result.subtotal == Decimal.new("150.00")
      assert result.total_tickets == 3
      # Platform: 150 * 0.025 + 0.50 * 3 = 3.75 + 1.50 = 5.25
      assert result.platform_fee == Decimal.new("5.25")
    end

    test "handles zero-price tickets" do
      items = [%{unit_price: Decimal.new("0"), quantity: 2}]
      result = Pricing.calculate(items)

      assert result.subtotal == Decimal.new("0")
      assert result.total_tickets == 2
    end
  end
end
