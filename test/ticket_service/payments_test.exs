defmodule TicketService.PaymentsTest do
  use TicketService.DataCase

  alias TicketService.Payments
  alias TicketService.Orders.Order
  alias TicketService.Repo

  setup do
    # Use mock Stripe client
    Application.put_env(:ticket_service, :stripe_client, TicketService.Payments.MockStripe)
    on_exit(fn -> Application.delete_env(:ticket_service, :stripe_client) end)
    :ok
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

  describe "handle_webhook_event/1" do
    test "payment_intent.succeeded confirms order" do
      order = create_test_order()
      {:ok, intent} = Payments.create_payment_intent(order)

      event = %{
        "type" => "payment_intent.succeeded",
        "data" => %{
          "object" => %{
            "id" => intent.payment_intent_id
          }
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

    test "unknown event type is ignored" do
      event = %{"type" => "customer.created", "data" => %{"object" => %{}}}
      assert {:ok, :ignored, "customer.created"} = Payments.handle_webhook_event(event)
    end
  end

  describe "refund_order/2" do
    test "processes full refund via mock Stripe" do
      order = create_test_order(%{status: "confirmed"})
      {:ok, _intent} = Payments.create_payment_intent(order)
      order = Repo.get!(Order, order.id)

      assert {:ok, refunded} = Payments.refund_order(order)
      assert refunded.status == "refunded"
      assert refunded.stripe_refund_id != nil
      assert refunded.refund_amount != nil
      assert refunded.refunded_at != nil
    end

    test "returns error when no payment intent exists" do
      order = create_test_order(%{status: "confirmed"})
      assert {:error, :no_payment_intent} = Payments.refund_order(order)
    end
  end

  describe "partial_refund/3" do
    test "processes partial refund" do
      order = create_test_order(%{status: "confirmed"})
      {:ok, _intent} = Payments.create_payment_intent(order)
      order = Repo.get!(Order, order.id)

      assert {:ok, refunded} = Payments.partial_refund(order, 5000)
      assert refunded.status == "partially_refunded"
      assert refunded.stripe_refund_id != nil
    end
  end
end
