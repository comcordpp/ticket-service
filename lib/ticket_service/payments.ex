defmodule TicketService.Payments do
  @moduledoc """
  Payments context — manages Stripe PaymentIntents with Connect split payments,
  webhook processing, and full/partial refund operations with audit trail.
  """
  import Ecto.Query

  alias Ecto.Multi
  alias TicketService.Repo
  alias TicketService.Orders
  alias TicketService.Orders.{Order, OrderItem}
  alias TicketService.Payments.Refund
  alias TicketService.ETickets
  alias TicketService.Carts
  alias TicketService.Tickets.Ticket

  @doc """
  Create a Stripe PaymentIntent for an order.

  When the event has an organizer with a connected Stripe account, creates a
  Connect PaymentIntent with application_fee_amount (platform + processing fees)
  and transfer_data directing funds to the organizer's connected account.

  Returns `{:ok, %{client_secret: ..., payment_intent_id: ...}}` on success.
  """
  def create_payment_intent(%Order{} = order) do
    order = Repo.preload(order, event: :organizer)
    amount_cents = decimal_to_cents(order.total)
    idempotency_key = "pi_order_#{order.id}"

    params =
      %{
        amount: amount_cents,
        currency: "usd",
        idempotency_key: idempotency_key,
        metadata: %{
          order_id: order.id,
          event_id: order.event_id,
          checkout_token: order.checkout_token
        }
      }
      |> maybe_add_connect_params(order)

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

  # --- Refund Operations ---

  @doc """
  Process a full refund for an order.

  Atomically:
  1. Validates refund is allowed (not over-refunding)
  2. Creates Stripe Refund with `reverse_transfer: true` for Connect payments
  3. Creates a Refund record with audit trail
  4. Updates order status to "refunded"
  5. Cancels all e-tickets
  6. Releases all held seats back to the available pool

  Options:
  - `:reason` — refund reason (default: "requested_by_customer")
  - `:initiated_by` — who initiated the refund (for audit trail)
  - `:refund_application_fee` — whether to refund platform fee proportionally (default: true)
  """
  def refund_order(%Order{} = order, opts \\ []) do
    reason = Keyword.get(opts, :reason, "requested_by_customer")
    initiated_by = Keyword.get(opts, :initiated_by, "system")
    refund_app_fee = Keyword.get(opts, :refund_application_fee, true)

    order = Repo.preload(order, [:order_items, event: :organizer])

    with :ok <- validate_refundable(order),
         :ok <- validate_refund_amount(order, decimal_to_cents(order.total)) do
      has_connect = has_connect_account?(order)

      refund_params = %{
        payment_intent: order.stripe_payment_intent_id,
        reason: reason,
        idempotency_key: "refund_full_#{order.id}",
        reverse_transfer: has_connect,
        refund_application_fee: has_connect && refund_app_fee
      }

      case stripe_client().create_refund(refund_params) do
        {:ok, %{id: stripe_refund_id, amount: refund_amount_cents}} ->
          refund_amount = cents_to_decimal(refund_amount_cents)
          fee_refund = if refund_app_fee, do: calculate_fee_refund(order, refund_amount), else: nil

          multi =
            Multi.new()
            |> Multi.insert(:refund, %Refund{}
              |> Refund.changeset(%{
                order_id: order.id,
                type: "full",
                amount: refund_amount,
                reason: reason,
                stripe_refund_id: stripe_refund_id,
                status: "succeeded",
                initiated_by: initiated_by,
                fee_refund_amount: fee_refund
              })
            )
            |> Multi.update(:order, Order.changeset(order, %{
              status: "refunded",
              stripe_refund_id: stripe_refund_id,
              refund_amount: refund_amount,
              refund_reason: reason,
              refunded_at: DateTime.utc_now() |> DateTime.truncate(:second)
            }))
            |> Multi.run(:cancel_tickets, fn _repo, _changes ->
              {count, _} = cancel_tickets_for_order(order.id)
              {:ok, count}
            end)
            |> Multi.run(:release_inventory, fn _repo, _changes ->
              release_order_inventory(order)
              {:ok, :released}
            end)

          case Repo.transaction(multi) do
            {:ok, %{order: updated_order, refund: refund}} ->
              {:ok, %{order: updated_order, refund: refund}}

            {:error, step, changeset, _changes} ->
              {:error, {step, changeset}}
          end

        {:error, %{message: message}} ->
          {:error, {:stripe_error, message}}

        {:error, reason} ->
          {:error, {:stripe_error, reason}}
      end
    end
  end

  @doc """
  Process a partial refund for selected line items.

  Atomically:
  1. Validates each line_item ID belongs to the order
  2. Calculates refund amount from selected items
  3. Validates total refunds don't exceed original payment
  4. Creates Stripe Refund with proportional fee handling
  5. Creates Refund records per line item with audit trail
  6. Cancels tickets for refunded line items
  7. Releases seats for refunded line items

  Options:
  - `:reason` — refund reason (default: "requested_by_customer")
  - `:initiated_by` — who initiated the refund (for audit trail)
  - `:refund_application_fee` — whether to refund platform fee proportionally (default: true)
  """
  def partial_refund(%Order{} = order, line_item_ids, opts \\ []) do
    reason = Keyword.get(opts, :reason, "requested_by_customer")
    initiated_by = Keyword.get(opts, :initiated_by, "system")
    refund_app_fee = Keyword.get(opts, :refund_application_fee, true)

    order = Repo.preload(order, [:order_items, event: :organizer])

    with {:ok, items_to_refund} <- validate_line_items(order, line_item_ids),
         refund_amount_cents <- calculate_line_items_total(items_to_refund),
         :ok <- validate_refund_amount(order, refund_amount_cents) do
      has_connect = has_connect_account?(order)

      refund_params = %{
        payment_intent: order.stripe_payment_intent_id,
        amount: refund_amount_cents,
        reason: reason,
        idempotency_key: "refund_partial_#{order.id}_#{Enum.sort(line_item_ids) |> Enum.join("_")}",
        reverse_transfer: has_connect,
        refund_application_fee: has_connect && refund_app_fee
      }

      case stripe_client().create_refund(refund_params) do
        {:ok, %{id: stripe_refund_id, amount: stripe_amount}} ->
          refund_amount = cents_to_decimal(stripe_amount)
          fee_refund = if refund_app_fee, do: calculate_fee_refund(order, refund_amount), else: nil

          # Determine if this makes the order fully refunded
          total_refunded = total_refunded_amount(order)
          new_total_refunded = Decimal.add(total_refunded, refund_amount)
          fully_refunded? = Decimal.compare(new_total_refunded, order.total) != :lt
          new_status = if fully_refunded?, do: "refunded", else: "partially_refunded"

          multi =
            Multi.new()
            |> insert_line_item_refunds(items_to_refund, order, stripe_refund_id, reason, initiated_by, fee_refund)
            |> Multi.update(:order, Order.changeset(order, %{
              status: new_status,
              stripe_refund_id: stripe_refund_id,
              refund_amount: new_total_refunded,
              refund_reason: reason,
              refunded_at: DateTime.utc_now() |> DateTime.truncate(:second)
            }))
            |> Multi.run(:cancel_tickets, fn _repo, _changes ->
              cancel_tickets_for_items(line_item_ids)
              {:ok, :cancelled}
            end)
            |> Multi.run(:release_inventory, fn _repo, _changes ->
              release_items_inventory(items_to_refund)
              {:ok, :released}
            end)

          case Repo.transaction(multi) do
            {:ok, %{order: updated_order} = results} ->
              refunds = collect_refunds_from_results(results)
              {:ok, %{order: updated_order, refunds: refunds}}

            {:error, step, changeset, _changes} ->
              {:error, {step, changeset}}
          end

        {:error, %{message: message}} ->
          {:error, {:stripe_error, message}}

        {:error, reason} ->
          {:error, {:stripe_error, reason}}
      end
    end
  end

  @doc """
  Process a partial refund by amount (without specific line items).
  """
  def partial_refund_by_amount(%Order{} = order, amount_cents, opts \\ []) do
    reason = Keyword.get(opts, :reason, "requested_by_customer")
    initiated_by = Keyword.get(opts, :initiated_by, "system")
    refund_app_fee = Keyword.get(opts, :refund_application_fee, true)

    order = Repo.preload(order, [:order_items, event: :organizer])

    with :ok <- validate_refundable(order),
         :ok <- validate_refund_amount(order, amount_cents) do
      has_connect = has_connect_account?(order)

      refund_params = %{
        payment_intent: order.stripe_payment_intent_id,
        amount: amount_cents,
        reason: reason,
        idempotency_key: "refund_partial_#{order.id}_#{amount_cents}_#{System.unique_integer([:positive])}",
        reverse_transfer: has_connect,
        refund_application_fee: has_connect && refund_app_fee
      }

      case stripe_client().create_refund(refund_params) do
        {:ok, %{id: stripe_refund_id, amount: stripe_amount}} ->
          refund_amount = cents_to_decimal(stripe_amount)
          fee_refund = if refund_app_fee, do: calculate_fee_refund(order, refund_amount), else: nil

          total_refunded = total_refunded_amount(order)
          new_total_refunded = Decimal.add(total_refunded, refund_amount)
          fully_refunded? = Decimal.compare(new_total_refunded, order.total) != :lt
          new_status = if fully_refunded?, do: "refunded", else: "partially_refunded"

          multi =
            Multi.new()
            |> Multi.insert(:refund, %Refund{}
              |> Refund.changeset(%{
                order_id: order.id,
                type: "partial",
                amount: refund_amount,
                reason: reason,
                stripe_refund_id: stripe_refund_id,
                status: "succeeded",
                initiated_by: initiated_by,
                fee_refund_amount: fee_refund
              })
            )
            |> Multi.update(:order, Order.changeset(order, %{
              status: new_status,
              stripe_refund_id: stripe_refund_id,
              refund_amount: new_total_refunded,
              refund_reason: reason,
              refunded_at: DateTime.utc_now() |> DateTime.truncate(:second)
            }))

          case Repo.transaction(multi) do
            {:ok, %{order: updated_order, refund: refund}} ->
              {:ok, %{order: updated_order, refund: refund}}

            {:error, step, changeset, _changes} ->
              {:error, {step, changeset}}
          end

        {:error, %{message: message}} ->
          {:error, {:stripe_error, message}}

        {:error, reason} ->
          {:error, {:stripe_error, reason}}
      end
    end
  end

  @doc "List all refunds for an order."
  def list_refunds(order_id) do
    Refund
    |> where([r], r.order_id == ^order_id)
    |> order_by([r], desc: r.inserted_at)
    |> Repo.all()
  end

  # --- Webhook Handling ---

  @doc """
  Handle Stripe webhook events.

  Supported events:
  - `payment_intent.succeeded` — confirms the order, generates e-tickets, clears cart
  - `payment_intent.payment_failed` — marks the order as failed
  - `charge.refunded` — updates order and refund records with refund status
  - `charge.refund.updated` — updates refund record status on async refund resolution
  """
  def handle_webhook_event(%{"type" => "payment_intent.succeeded", "data" => %{"object" => object}}) do
    intent_id = object["id"]

    case get_order_by_intent(intent_id) do
      nil ->
        {:error, :order_not_found}

      order ->
        with {:ok, confirmed} <- Orders.confirm_order(order) do
          if order.session_id do
            Task.start(fn -> Carts.clear_cart(order.session_id, release_inventory: false) end)
          end

          {:ok, confirmed}
        end
    end
  end

  def handle_webhook_event(%{"type" => "payment_intent.payment_failed", "data" => %{"object" => object}}) do
    intent_id = object["id"]

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

  def handle_webhook_event(%{"type" => "charge.refund.updated", "data" => %{"object" => object}}) do
    stripe_refund_id = object["id"]
    status = object["status"]

    case get_refund_by_stripe_id(stripe_refund_id) do
      nil ->
        {:ok, :ignored, "charge.refund.updated"}

      refund ->
        new_status =
          case status do
            "succeeded" -> "succeeded"
            "failed" -> "failed"
            "canceled" -> "failed"
            _ -> refund.status
          end

        refund
        |> Refund.changeset(%{status: new_status})
        |> Repo.update()
    end
  end

  def handle_webhook_event(%{"type" => type}) do
    {:ok, :ignored, type}
  end

  @doc "Verify a Stripe webhook signature."
  def verify_webhook_signature(payload, signature, secret) do
    stripe_client().verify_webhook(payload, signature, secret)
  end

  # --- Private: Validation ---

  defp validate_refundable(%Order{stripe_payment_intent_id: nil}), do: {:error, :no_payment_intent}
  defp validate_refundable(%Order{status: status}) when status in ["confirmed", "partially_refunded"], do: :ok
  defp validate_refundable(%Order{status: status}), do: {:error, {:not_refundable, status}}

  defp validate_refund_amount(order, amount_cents) do
    total_cents = decimal_to_cents(order.total)
    already_refunded_cents = total_refunded_cents(order)
    remaining = total_cents - already_refunded_cents

    if amount_cents > remaining do
      {:error, {:exceeds_refundable_amount, %{requested: amount_cents, remaining: remaining}}}
    else
      :ok
    end
  end

  defp validate_line_items(order, line_item_ids) do
    order_item_ids = MapSet.new(order.order_items, & &1.id)
    requested_ids = MapSet.new(line_item_ids)
    invalid = MapSet.difference(requested_ids, order_item_ids)

    if MapSet.size(invalid) == 0 do
      items = Enum.filter(order.order_items, &(&1.id in requested_ids))
      {:ok, items}
    else
      {:error, {:invalid_line_items, MapSet.to_list(invalid)}}
    end
  end

  # --- Private: Calculations ---

  defp calculate_line_items_total(items) do
    items
    |> Enum.map(fn item -> Decimal.mult(item.unit_price, item.quantity) end)
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
    |> decimal_to_cents()
  end

  defp calculate_fee_refund(order, refund_amount) do
    total_fee = Decimal.add(order.platform_fee, order.processing_fee)

    if Decimal.compare(order.total, 0) == :gt do
      ratio = Decimal.div(refund_amount, order.total)
      Decimal.mult(total_fee, ratio) |> Decimal.round(2)
    else
      Decimal.new(0)
    end
  end

  defp total_refunded_amount(order) do
    Refund
    |> where([r], r.order_id == ^order.id and r.status == "succeeded")
    |> Repo.aggregate(:sum, :amount) || Decimal.new(0)
  end

  defp total_refunded_cents(order) do
    total_refunded_amount(order) |> decimal_to_cents()
  end

  # --- Private: Inventory & Ticket Release ---

  defp release_order_inventory(order) do
    Enum.each(order.order_items, fn item ->
      Carts.release_inventory_on_expiry(item.ticket_type_id, item.quantity, item.seat_ids)
    end)
  end

  defp release_items_inventory(items) do
    Enum.each(items, fn item ->
      Carts.release_inventory_on_expiry(item.ticket_type_id, item.quantity, item.seat_ids)
    end)
  end

  defp cancel_tickets_for_order(order_id) do
    from(t in Ticket,
      where: t.order_id == ^order_id and t.status == "active"
    )
    |> Repo.update_all(set: [status: "cancelled", updated_at: DateTime.utc_now() |> DateTime.truncate(:second)])
  end

  defp cancel_tickets_for_items(order_item_ids) do
    from(t in Ticket,
      where: t.order_item_id in ^order_item_ids and t.status == "active"
    )
    |> Repo.update_all(set: [status: "cancelled", updated_at: DateTime.utc_now() |> DateTime.truncate(:second)])
  end

  # --- Private: Multi Helpers ---

  defp insert_line_item_refunds(multi, items, order, stripe_refund_id, reason, initiated_by, fee_refund) do
    total_refund_amount =
      items
      |> Enum.map(fn item -> Decimal.mult(item.unit_price, item.quantity) end)
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    Enum.reduce(items, multi, fn item, acc ->
      item_amount = Decimal.mult(item.unit_price, item.quantity)

      item_fee_refund =
        if fee_refund && Decimal.compare(total_refund_amount, 0) == :gt do
          ratio = Decimal.div(item_amount, total_refund_amount)
          Decimal.mult(fee_refund, ratio) |> Decimal.round(2)
        else
          nil
        end

      Multi.insert(acc, {:refund, item.id}, %Refund{}
        |> Refund.changeset(%{
          order_id: order.id,
          order_item_id: item.id,
          type: "partial",
          amount: item_amount,
          reason: reason,
          stripe_refund_id: stripe_refund_id,
          status: "succeeded",
          initiated_by: initiated_by,
          fee_refund_amount: item_fee_refund
        })
      )
    end)
  end

  defp collect_refunds_from_results(results) do
    results
    |> Enum.filter(fn
      {{:refund, _id}, %Refund{}} -> true
      _ -> false
    end)
    |> Enum.map(fn {_key, refund} -> refund end)
  end

  # --- Private: Connect Helpers ---

  defp maybe_add_connect_params(params, %{event: %{organizer: %{stripe_account_id: account_id, stripe_charges_enabled: true}}} = order) when is_binary(account_id) do
    application_fee_cents = decimal_to_cents(Decimal.add(order.platform_fee, order.processing_fee))

    params
    |> Map.put(:application_fee_amount, application_fee_cents)
    |> Map.put(:transfer_data, %{destination: account_id})
  end

  defp maybe_add_connect_params(params, _order), do: params

  defp has_connect_account?(%{event: %{organizer: %{stripe_account_id: id, stripe_charges_enabled: true}}}) when is_binary(id), do: true
  defp has_connect_account?(_), do: false

  # --- Private: Lookups ---

  defp get_order_by_intent(intent_id) do
    Order
    |> where([o], o.stripe_payment_intent_id == ^intent_id)
    |> Repo.one()
    |> case do
      nil -> nil
      order -> Repo.preload(order, :order_items)
    end
  end

  defp get_refund_by_stripe_id(stripe_refund_id) do
    Refund
    |> where([r], r.stripe_refund_id == ^stripe_refund_id)
    |> Repo.one()
  end

  # --- Private: Conversions ---

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
