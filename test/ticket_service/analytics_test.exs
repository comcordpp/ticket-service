defmodule TicketService.AnalyticsTest do
  use ExUnit.Case, async: false

  alias TicketService.Analytics

  @event_id "test-event-analytics"

  setup do
    start_supervised!(Analytics)
    :ok
  end

  test "records and retrieves sales metrics" do
    Analytics.record_sale(@event_id, 5)
    Analytics.record_sale(@event_id, 3)

    snapshot = Analytics.get_snapshot(@event_id)
    assert snapshot.sales_per_minute == 8
    assert snapshot.total_sales_last_hour == 8
  end

  test "tracks cart conversion rate" do
    for _ <- 1..10, do: Analytics.record_cart_created(@event_id)
    for _ <- 1..3, do: Analytics.record_checkout(@event_id)

    snapshot = Analytics.get_snapshot(@event_id)
    assert snapshot.cart_conversion_rate == 30.0
  end

  test "returns timeseries data" do
    Analytics.record_sale(@event_id, 10)
    series = Analytics.get_timeseries(@event_id, :sales, 5)

    assert length(series) == 5
    # Last entry should have our sales
    last = List.last(series)
    assert last.value == 10
  end

  test "snapshot returns zeros for unknown event" do
    snapshot = Analytics.get_snapshot("unknown-event")
    assert snapshot.sales_per_minute == 0
    assert snapshot.cart_conversion_rate == 0.0
  end
end
