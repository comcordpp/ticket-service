defmodule TicketService.PaymentsTest do
  use TicketService.DataCase

  alias TicketService.Payments
  alias TicketService.Payments.Refund
  alias TicketService.Orders.{Order, OrderItem}
  alias TicketService.Tickets.Ticket
  alias TicketService.Repo

  setup do
    Application.put_env(:ticket_service, :stripe_client, TicketService.Payments.MockStripe)
    on_exit(fn -> Application.delete_env(:ticket_service, :stripe_client) end)
    :ok
  end

  defp create_test_event do
    venue = Repo.insert!(%TicketService.Venues.Venue{
      name: "Test Venue",
      capacity: 1000
    })

    Repo.insert!(%TicketService.Events.Event{
      title: "Test Event",
      starts_at: DateTime.add(DateTime.utc_now(), 86400, :second) |> DateTime.truncate(:second),
      status: "published",
      venue_id: venue.id
    })
  end

  defp create_test_order(attrs \\ %{}) do
    defaults = %{
      session_id: "test-session-#{System.unique_integer([:positive])}",
      status: "pending",
      subtotal: Decimal.new("100.00"),
      platform_fee: Decimal.new("3.00"),
      processing_fee: Decimal.new("3.29"),
      total: Decimal.new("106.29"),
      checkout_token: "token-#{:crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)}",
      checkout_expires_at: DateTime.add(DateTime.utc_now(), 900, :second) |> DateTime.truncate(:second),
      event_id: create_test_event().id
    }

    %Order{}
    |> Order.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp create_order_with_items(order_attrs \\ %{}) do
    order = create_test_order(order_attrs)

    ticket_type = Repo.insert!(%TicketService.Tickets.TicketType{
      name: "GA",
      price: Decimal.new("50.00"),
      quantity: 100,
      event_id: order.event_id
    })

    item1 = Repo.insert!(%OrderItem{
      order_id: order.id,
      ticket_type_id: ticket_type.id,
      quantity: 1,
      unit_price: Decimal.new("50.00"),
      seat_ids: []
    })

    item2 = Repo.insert!(%OrderItem{
      order_id: order.id,
      ticket_type_id: ticket_type.id,
      quantity: 1,
      unit_price: Decimal.new("50.00"),
      seat_ids: []
    })

    order = Repo.preload(order, :order_items)
    {order, [item1, item2]}
  end

  defp create_tickets_for_order(order) do
    order = Repo.preload(order, :order_items)

    Enum.flat_map(order.order_items, fn item ->
      Enum.map(1..item.quantity, fn _ ->
        token = :crypto.strong_rand_bytes(20) |> Base.url_encode64(padding: false)
        qr_hash = :crypto.hash(:sha256, token) |> Base.url_encode64(padding: false)

        Repo.insert!(%Ticket{
          token: token,
          qr_data: "<svg>test</svg>",
          qr_hash: qr_hash,
          status: "sold",
          order_id: order.id,
          order_item_id: item.id,
          event_id: order.event_id
        })
      end)
    end)
  end

  defp setup_confirmed_order_with_intent(extra_attrs \\ %{}) do
    {order, items} = create_order_with_items(extra_attrs)
    {:ok, _intent} = Payments.create_payment_intent(order)
    order = Repo.get!(Order, order.id) |> Repo.preload(:order_items)

    # Manually confirm so we can refund
    order
    |> Order.changeset(%{status: "confirmed"})
    |> Repo.update!()
    |> Repo.preload(:order_items)
    |> then(&{&1, items})
  end

  # --- PaymentIntent Tests ---

  describe "create_payment_intent/1" do
    test "creates a PaymentIntent and stores intent ID on order" do
      order = create_test_order()
      assert {:ok, intent} = Payments.create_payment_intent(order)

      assert intent.client_secret != nil
      assert intent.payment_intent_id != nil
      assert String.starts_with?(intent.payment_intent_id, "pi_test_")

      updated_order = Repo.get!(Order, order.id)
      assert updated_order.stripe_payment_intent_id == intent.payment_intent_id
    end
  end

  # --- Full Refund Tests ---

  describe "refund_order/2" do
    test "processes full refund with Refund record and order update" do
      {order, _items} = setup_confirmed_order_with_intent()

      assert {:ok, %{order: refunded_order, refund: refund}} =
        Payments.refund_order(order, reason: "duplicate", initiated_by: "admin@test.com")

      assert refunded_order.status == "refunded"
      assert refunded_order.stripe_refund_id != nil
      assert refunded_order.refund_amount != nil
      assert refunded_order.refunded_at != nil

      assert refund.type == "full"
      assert refund.status == "succeeded"
      assert refund.reason == "duplicate"
      assert refund.initiated_by == "admin@test.com"
      assert refund.stripe_refund_id != nil
      assert refund.order_id == order.id
    end

    test "cancels all active tickets on full refund" do
      {order, _items} = setup_confirmed_order_with_intent()
      tickets = create_tickets_for_order(order)
      assert length(tickets) > 0

      assert {:ok, _} = Payments.refund_order(order)

      Enum.each(tickets, fn ticket ->
        updated = Repo.get!(Ticket, ticket.id)
        assert updated.status == "cancelled"
      end)
    end

    test "returns error when no payment intent exists" do
      order = create_test_order(%{status: "confirmed"})
      assert {:error, :no_payment_intent} = Payments.refund_order(order)
    end

    test "returns error when order is not refundable" do
      order = create_test_order(%{status: "pending"})
      assert {:error, {:not_refundable, "pending"}} = Payments.refund_order(order)
    end

    test "calculates proportional fee refund" do
      {order, _items} = setup_confirmed_order_with_intent()

      assert {:ok, %{refund: refund}} = Payments.refund_order(order)
      assert refund.fee_refund_amount != nil
      assert Decimal.compare(refund.fee_refund_amount, Decimal.new(0)) == :gt
    end
  end

  # --- Partial Refund by Line Items ---

  describe "partial_refund/3 (line items)" do
    test "refunds selected line items and creates per-item refund records" do
      {order, [item1, _item2]} = setup_confirmed_order_with_intent()

      assert {:ok, %{order: updated, refunds: refunds}} =
        Payments.partial_refund(order, [item1.id], reason: "wrong_item")

      assert updated.status == "partially_refunded"
      assert length(refunds) == 1

      refund = hd(refunds)
      assert refund.order_item_id == item1.id
      assert refund.type == "partial"
      assert refund.reason == "wrong_item"
      assert Decimal.compare(refund.amount, Decimal.new("50.00")) == :eq
    end

    test "cancels tickets only for refunded line items" do
      {order, [item1, item2]} = setup_confirmed_order_with_intent()
      _tickets = create_tickets_for_order(order)

      assert {:ok, _} = Payments.partial_refund(order, [item1.id])

      # Tickets for item1 should be cancelled
      item1_tickets = Repo.all(from t in Ticket, where: t.order_item_id == ^item1.id)
      Enum.each(item1_tickets, fn t -> assert t.status == "cancelled" end)

      # Tickets for item2 should still be active
      item2_tickets = Repo.all(from t in Ticket, where: t.order_item_id == ^item2.id)
      Enum.each(item2_tickets, fn t -> assert t.status == "sold" end)
    end

    test "returns error for invalid line item IDs" do
      {order, _items} = setup_confirmed_order_with_intent()
      fake_id = Ecto.UUID.generate()

      assert {:error, {:invalid_line_items, [^fake_id]}} =
        Payments.partial_refund(order, [fake_id])
    end

    test "marks order as fully refunded when all items are refunded" do
      {order, [item1, item2]} = setup_confirmed_order_with_intent()

      assert {:ok, %{order: partial}} = Payments.partial_refund(order, [item1.id])
      assert partial.status == "partially_refunded"

      # Reload to get updated refund_amount
      order = Repo.get!(Order, order.id) |> Repo.preload(:order_items)

      assert {:ok, %{order: full}} = Payments.partial_refund(order, [item2.id])
      assert full.status == "refunded"
    end
  end

  # --- Partial Refund by Amount ---

  describe "partial_refund_by_amount/3" do
    test "processes partial refund by amount" do
      {order, _items} = setup_confirmed_order_with_intent()

      assert {:ok, %{order: updated, refund: refund}} =
        Payments.partial_refund_by_amount(order, 5000, reason: "goodwill")

      assert updated.status == "partially_refunded"
      assert refund.type == "partial"
      assert Decimal.compare(refund.amount, Decimal.new("50.00")) == :eq
    end

    test "prevents over-refunding" do
      {order, _items} = setup_confirmed_order_with_intent()

      # First partial refund succeeds
      assert {:ok, _} = Payments.partial_refund_by_amount(order, 5000)

      # Reload order
      order = Repo.get!(Order, order.id) |> Repo.preload(:order_items)

      # Trying to refund more than remaining should fail
      too_much = 10000
      assert {:error, {:exceeds_refundable_amount, _}} =
        Payments.partial_refund_by_amount(order, too_much)
    end
  end

  # --- Refund Listing ---

  describe "list_refunds/1" do
    test "returns all refunds for an order" do
      {order, _items} = setup_confirmed_order_with_intent()

      assert {:ok, _} = Payments.partial_refund_by_amount(order, 2000)
      order = Repo.get!(Order, order.id) |> Repo.preload(:order_items)
      assert {:ok, _} = Payments.partial_refund_by_amount(order, 2000)

      refunds = Payments.list_refunds(order.id)
      assert length(refunds) == 2
    end
  end

  # --- Webhook Tests ---

  describe "handle_webhook_event/1" do
    test "payment_intent.succeeded confirms order" do
      order = create_test_order()
      {:ok, intent} = Payments.create_payment_intent(order)

      event = %{
        "type" => "payment_intent.succeeded",
        "data" => %{
          "object" => %{"id" => intent.payment_intent_id}
        }
      }

      assert {:ok, confirmed} = Payments.handle_webhook_event(event)
      assert confirmed.status == "confirmed"
    end

    test "payment_intent.payment_failed cancels order" do
      order = create_test_order()
      {:ok, intent} = Payments.create_payment_intent(order)

      event = %{
        "type" => "payment_intent.payment_failed",
        "data" => %{
          "object" => %{
            "id" => intent.payment_intent_id,
            "last_payment_error" => %{"message" => "Card declined"}
          }
        }
      }

      assert {:ok, cancelled} = Payments.handle_webhook_event(event)
      assert cancelled.status == "cancelled"
    end

    test "charge.refunded updates order status" do
      order = create_test_order(%{status: "confirmed"})
      {:ok, intent} = Payments.create_payment_intent(order)

      event = %{
        "type" => "charge.refunded",
        "data" => %{
          "object" => %{
            "payment_intent" => intent.payment_intent_id,
            "amount_refunded" => 10629
          }
        }
      }

      assert {:ok, refunded} = Payments.handle_webhook_event(event)
      assert refunded.status == "refunded"
    end

    test "charge.refund.updated updates refund record status" do
      {order, _items} = setup_confirmed_order_with_intent()
      {:ok, %{refund: refund}} = Payments.refund_order(order)

      event = %{
        "type" => "charge.refund.updated",
        "data" => %{
          "object" => %{
            "id" => refund.stripe_refund_id,
            "status" => "succeeded"
          }
        }
      }

      assert {:ok, updated_refund} = Payments.handle_webhook_event(event)
      assert updated_refund.status == "succeeded"
    end

    test "charge.refund.updated with failed status" do
      {order, _items} = setup_confirmed_order_with_intent()
      {:ok, %{refund: refund}} = Payments.refund_order(order)

      event = %{
        "type" => "charge.refund.updated",
        "data" => %{
          "object" => %{
            "id" => refund.stripe_refund_id,
            "status" => "failed"
          }
        }
      }

      assert {:ok, updated_refund} = Payments.handle_webhook_event(event)
      assert updated_refund.status == "failed"
    end

    test "unknown event type is ignored" do
      event = %{"type" => "customer.created", "data" => %{"object" => %{}}}
      assert {:ok, :ignored, "customer.created"} = Payments.handle_webhook_event(event)
    end
  end
end
