defmodule TicketService.ETicketsTest do
  use TicketService.DataCase

  alias TicketService.ETickets
  alias TicketService.Orders.{Order, OrderItem}
  alias TicketService.Tickets.Ticket
  alias TicketService.Repo

  defp create_confirmed_order do
    venue = Repo.insert!(%TicketService.Venues.Venue{
      name: "Test Venue",
      capacity: 1000
    })

    event = Repo.insert!(%TicketService.Events.Event{
      title: "Test Concert",
      starts_at: DateTime.add(DateTime.utc_now(), 86400, :second) |> DateTime.truncate(:second),
      status: "published",
      venue_id: venue.id
    })

    ticket_type = Repo.insert!(%TicketService.Tickets.TicketType{
      name: "General Admission",
      price: Decimal.new("50.00"),
      quantity: 100,
      event_id: event.id
    })

    order = Repo.insert!(%Order{
      session_id: "test-session",
      status: "confirmed",
      subtotal: Decimal.new("150.00"),
      platform_fee: Decimal.new("5.25"),
      processing_fee: Decimal.new("4.81"),
      total: Decimal.new("160.06"),
      event_id: event.id,
      checkout_token: "test-token-#{System.unique_integer([:positive])}",
      checkout_expires_at: DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second)
    })

    order_item = Repo.insert!(%OrderItem{
      order_id: order.id,
      ticket_type_id: ticket_type.id,
      quantity: 3,
      unit_price: Decimal.new("50.00")
    })

    {order, order_item, event}
  end

  describe "generate_for_order/2" do
    test "generates one ticket per quantity" do
      {order, _item, _event} = create_confirmed_order()
      assert {:ok, tickets} = ETickets.generate_for_order(order)
      assert length(tickets) == 3
    end

    test "each ticket has unique token and QR data" do
      {order, _item, _event} = create_confirmed_order()
      {:ok, tickets} = ETickets.generate_for_order(order)

      tokens = Enum.map(tickets, & &1.token)
      assert length(Enum.uniq(tokens)) == 3

      Enum.each(tickets, fn t ->
        assert t.qr_data != nil
        assert String.contains?(t.qr_data, "<svg")
      end)
    end

    test "stores holder email when provided" do
      {order, _item, _event} = create_confirmed_order()
      {:ok, tickets} = ETickets.generate_for_order(order, email: "buyer@example.com")

      Enum.each(tickets, fn t ->
        assert t.holder_email == "buyer@example.com"
      end)
    end
  end

  describe "scan_ticket/1" do
    test "marks ticket as used on first scan" do
      {order, _item, _event} = create_confirmed_order()
      {:ok, [ticket | _]} = ETickets.generate_for_order(order)

      assert {:ok, scanned} = ETickets.scan_ticket(ticket.token)
      assert scanned.status == "used"
      assert scanned.scanned_at != nil
    end

    test "rejects already scanned ticket" do
      {order, _item, _event} = create_confirmed_order()
      {:ok, [ticket | _]} = ETickets.generate_for_order(order)

      {:ok, _} = ETickets.scan_ticket(ticket.token)
      assert {:error, :already_scanned} = ETickets.scan_ticket(ticket.token)
    end

    test "returns error for unknown token" do
      assert {:error, :ticket_not_found} = ETickets.scan_ticket("nonexistent")
    end
  end

  describe "cancel_tickets_for_order/1" do
    test "cancels all active tickets" do
      {order, _item, _event} = create_confirmed_order()
      {:ok, tickets} = ETickets.generate_for_order(order)

      {count, _} = ETickets.cancel_tickets_for_order(order.id)
      assert count == 3

      cancelled = ETickets.list_tickets_for_order(order.id)
      Enum.each(cancelled, fn t -> assert t.status == "cancelled" end)
    end
  end
end
