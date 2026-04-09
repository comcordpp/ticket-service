defmodule TicketService.Payments do
  @moduledoc """
  Payments context — manages Stripe PaymentIntents, webhook processing,
  and refund operations.
  """
  import Ecto.Query

  alias TicketService.Repo
  alias TicketService.Orders
  alias TicketService.Orders.Order

  @doc """
  Create a Stripe PaymentIntent for an order.

  Converts the order total to cents for Stripe and creates a PaymentIntent.
  Returns `{:ok, %{client_secret: ..., payment_intent_id: ...}}` on success.
  """
  def create_payment_intent(%Order{} = order) do
    amount_cents = decimal_to_cents(order.total)

    params = %{
      amount: amount_cents,
      currency: "usd",
      metadata: %{
        order_id: order.id,
        event_id: order.event_id,
        checkout_token: order.checkout_token
      }
    }

    case stripe_client().create_payment_intent(params) do
      {:ok, %{id: intent_id, client_secret: client_secret}} ->
        {:ok, _updated} =
          order
          |> Order.changeset(%{stripe_payment_intent_id: intent_id})
          |> Repo.update()

        {:ok, %{client_secret: client_secret, payment_intent_id: intent_id}}

      {:error, %{message: message}} ->
        {:error, {:stripe_error, message}}

      {:error, reason} ->
        {:error, {:stripe_error, reason}}
    end
  end

  @doc """
  Handle Stripe webhook events.

  Supported events:
  - `payment_intent.succeeded` — confirms the order and triggers e-ticket generation
  - `payment_intent.payment_failed` — marks the order as failed
  - `charge.refunded` — marks the order as refunded
  """
  def handle_webhook_event(%{"type" => "payment_intent.succeeded", "data" => %{"object" => object}}) do
    intent_id = object["id"]

    case get_order_by_intent(intent_id) do
      nil -> {:error, :order_not_found}
      order -> Orders.confirm_order(order)
    end
  end

  def handle_webhook_event(%{"type" => "payment_intent.payment_failed", "data" => %{"object" => object}}) do
    intent_id = object["id"]
    error_message = get_in(object, ["last_payment_error", "message"]) || "Payment failed"

    case get_order_by_intent(intent_id) do
      nil ->
        {:error, :order_not_found}

      order ->
        order
        |> Order.changeset(%{status: "cancelled"})
        |> Repo.update()
    end
  end

  def handle_webhook_event(%{"type" => "charge.refunded", "data" => %{"object" => object}}) do
    intent_id = object["payment_intent"]
    refund_amount = object["amount_refunded"]

    case get_order_by_intent(intent_id) do
      nil ->
        {:error, :order_not_found}

      order ->
        amount_decimal = cents_to_decimal(refund_amount)
        full_refund? = Decimal.compare(amount_decimal, order.total) != :lt

        order
        |> Order.changeset(%{
          status: if(full_refund?, do: "refunded", else: "partially_refunded"),
          refund_amount: amount_decimal,
          refunded_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update()
    end
  end

  def handle_webhook_event(%{"type" => type}) do
    {:ok, :ignored, type}
  end

  @doc """
  Process a full refund for an order via Stripe.
  """
  def refund_order(%Order{} = order, opts \\ []) do
    reason = Keyword.get(opts, :reason, "requested_by_customer")

    case order.stripe_payment_intent_id do
      nil ->
        {:error, :no_payment_intent}

      intent_id ->
        refund_params = %{
          payment_intent: intent_id,
          reason: reason
        }

        case stripe_client().create_refund(refund_params) do
          {:ok, %{id: refund_id, amount: refund_amount}} ->
            amount_decimal = cents_to_decimal(refund_amount)

            {:ok, updated} =
              order
              |> Order.changeset(%{
                status: "refunded",
                stripe_refund_id: refund_id,
                refund_amount: amount_decimal,
                refund_reason: reason,
                refunded_at: DateTime.utc_now() |> DateTime.truncate(:second)
              })
              |> Repo.update()

            # Release inventory
            release_order_inventory(updated)

            {:ok, updated}

          {:error, %{message: message}} ->
            {:error, {:stripe_error, message}}

          {:error, reason} ->
            {:error, {:stripe_error, reason}}
        end
    end
  end

  @doc """
  Process a partial refund for specific amount.
  """
  def partial_refund(%Order{} = order, amount_cents, opts \\ []) do
    reason = Keyword.get(opts, :reason, "requested_by_customer")

    case order.stripe_payment_intent_id do
      nil ->
        {:error, :no_payment_intent}

      intent_id ->
        refund_params = %{
          payment_intent: intent_id,
          amount: amount_cents,
          reason: reason
        }

        case stripe_client().create_refund(refund_params) do
          {:ok, %{id: refund_id, amount: refund_amount}} ->
            amount_decimal = cents_to_decimal(refund_amount)

            {:ok, updated} =
              order
              |> Order.changeset(%{
                status: "partially_refunded",
                stripe_refund_id: refund_id,
                refund_amount: amount_decimal,
                refund_reason: reason,
                refunded_at: DateTime.utc_now() |> DateTime.truncate(:second)
              })
              |> Repo.update()

            {:ok, updated}

          {:error, %{message: message}} ->
            {:error, {:stripe_error, message}}

          {:error, reason} ->
            {:error, {:stripe_error, reason}}
        end
    end
  end

  @doc "Verify a Stripe webhook signature."
  def verify_webhook_signature(payload, signature, secret) do
    stripe_client().verify_webhook(payload, signature, secret)
  end

  # --- Private ---

  defp get_order_by_intent(intent_id) do
    Order
    |> where([o], o.stripe_payment_intent_id == ^intent_id)
    |> Repo.one()
    |> case do
      nil -> nil
      order -> Repo.preload(order, :order_items)
    end
  end

  defp release_order_inventory(order) do
    order = Repo.preload(order, :order_items)

    Enum.each(order.order_items, fn item ->
      TicketService.Carts.release_inventory_on_expiry(item.ticket_type_id, item.quantity, item.seat_ids)
    end)
  end

  defp decimal_to_cents(decimal) do
    decimal
    |> Decimal.mult(100)
    |> Decimal.round(0)
    |> Decimal.to_integer()
  end

  defp cents_to_decimal(cents) when is_integer(cents) do
    cents |> Decimal.new() |> Decimal.div(100) |> Decimal.round(2)
  end

  defp stripe_client do
    Application.get_env(:ticket_service, :stripe_client, TicketService.Payments.StripeClient)
  end
end
