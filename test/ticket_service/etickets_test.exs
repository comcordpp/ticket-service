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
      assert scanned.status == "scanned"
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
    test "cancels all sold/delivered tickets" do
      {order, _item, _event} = create_confirmed_order()
      {:ok, tickets} = ETickets.generate_for_order(order)

      {count, _} = ETickets.cancel_tickets_for_order(order.id)
      assert count == 3

      cancelled = ETickets.list_tickets_for_order(order.id)
      Enum.each(cancelled, fn t -> assert t.status == "cancelled" end)
    end
  end

  describe "HMAC QR payload" do
    test "generates tickets with HMAC-signed QR payload" do
      {order, _item, _event} = create_confirmed_order()
      {:ok, [ticket | _]} = ETickets.generate_for_order(order)

      assert ticket.qr_payload != nil
      assert ticket.qr_hash != nil

      # Payload format: ticket_id:order_id:event_id:hmac
      parts = String.split(ticket.qr_payload, ":")
      assert length(parts) == 4

      [tid, oid, eid, _hmac] = parts
      assert tid == ticket.id
      assert oid == order.id
    end

    test "verify_hmac succeeds for valid payload" do
      {order, _item, _event} = create_confirmed_order()
      {:ok, [ticket | _]} = ETickets.generate_for_order(order)

      assert :ok = ETickets.verify_hmac(ticket.qr_payload)
    end

    test "verify_hmac fails for tampered payload" do
      {order, _item, _event} = create_confirmed_order()
      {:ok, [ticket | _]} = ETickets.generate_for_order(order)

      tampered = String.replace(ticket.qr_payload, order.id, Ecto.UUID.generate())
      assert {:error, :invalid_hmac} = ETickets.verify_hmac(tampered)
    end
  end

  describe "validate_qr/1" do
    test "validates and returns ticket for valid QR payload" do
      {order, _item, _event} = create_confirmed_order()
      {:ok, [ticket | _]} = ETickets.generate_for_order(order)

      assert {:ok, found} = ETickets.validate_qr(ticket.qr_payload)
      assert found.id == ticket.id
    end

    test "rejects invalid QR format" do
      assert {:error, :invalid_qr_format} = ETickets.validate_qr("not-a-valid-payload")
    end

    test "rejects tampered QR payload" do
      {order, _item, _event} = create_confirmed_order()
      {:ok, [ticket | _]} = ETickets.generate_for_order(order)

      tampered = String.replace(ticket.qr_payload, order.id, Ecto.UUID.generate())
      assert {:error, :invalid_hmac} = ETickets.validate_qr(tampered)
    end
  end

  describe "scan_by_qr/1" do
    test "scans ticket via QR payload" do
      {order, _item, _event} = create_confirmed_order()
      {:ok, [ticket | _]} = ETickets.generate_for_order(order)

      assert {:ok, scanned} = ETickets.scan_by_qr(ticket.qr_payload)
      assert scanned.status == "scanned"
      assert scanned.scanned_at != nil
    end

    test "rejects double scan via QR" do
      {order, _item, _event} = create_confirmed_order()
      {:ok, [ticket | _]} = ETickets.generate_for_order(order)

      {:ok, _} = ETickets.scan_by_qr(ticket.qr_payload)
      assert {:error, :already_scanned, _} = ETickets.scan_by_qr(ticket.qr_payload)
    end
  end

  describe "mark_delivered/1" do
    test "transitions tickets from sold to delivered" do
      {order, _item, _event} = create_confirmed_order()
      {:ok, tickets} = ETickets.generate_for_order(order)

      ticket_ids = Enum.map(tickets, & &1.id)
      {count, _} = ETickets.mark_delivered(ticket_ids)
      assert count == 3

      delivered = ETickets.list_tickets_for_order(order.id)
      Enum.each(delivered, fn t ->
        assert t.status == "delivered"
        assert t.emailed_at != nil
        assert t.delivered_at != nil
      end)
    end
  end

  describe "generate_qr_png/1" do
    test "returns PNG binary" do
      {order, _item, _event} = create_confirmed_order()
      {:ok, [ticket | _]} = ETickets.generate_for_order(order)

      png = ETickets.generate_qr_png(ticket)
      assert is_binary(png)
      # PNG magic bytes
      assert <<137, 80, 78, 71, _rest::binary>> = png
    end
  end
end
