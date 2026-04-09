defmodule TicketServiceWeb.PaymentController do
  use TicketServiceWeb, :controller

  alias TicketService.Orders
  alias TicketService.Payments
  alias TicketService.Repo

  @doc """
  Create a Stripe PaymentIntent for an order.

  POST /api/orders/token/:token/pay
  Body: { "email": "buyer@example.com", "name": "John Doe" }
  """
  def create_intent(conn, %{"token" => token}) do
    with {:ok, order} <- Orders.get_order_by_token(token),
         {:ok, intent} <- Payments.create_payment_intent(order) do
      conn
      |> put_status(:created)
      |> json(%{
        data: %{
          client_secret: intent.client_secret,
          payment_intent_id: intent.payment_intent_id,
          order_id: order.id,
          total: order.total
        }
      })
    else
      {:error, :invalid_or_expired_token} ->
        conn |> put_status(:not_found) |> json(%{error: "Invalid or expired checkout token"})

      {:error, {:stripe_error, message}} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Payment error: #{message}"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})
    end
  end

  @doc """
  Process a refund for a confirmed order.

  POST /api/orders/:id/refund
  Body:
    Full:    { "type": "full", "reason": "requested_by_customer" }
    Partial: { "type": "partial", "line_items": ["item-uuid-1", "item-uuid-2"], "reason": "..." }
    Amount:  { "type": "partial", "amount_cents": 5000, "reason": "..." }
  """
  def refund(conn, %{"id" => id} = params) do
    case Orders.get_order(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Order not found"})

      %{status: status} when status not in ["confirmed", "partially_refunded"] ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Order cannot be refunded (status: #{status})"})

      order ->
        reason = Map.get(params, "reason", "requested_by_customer")
        initiated_by = Map.get(params, "initiated_by", "organizer")
        refund_type = Map.get(params, "type", "full")
        refund_opts = [reason: reason, initiated_by: initiated_by]

        result =
          case refund_type do
            "full" ->
              Payments.refund_order(order, refund_opts)

            "partial" ->
              cond do
                is_list(Map.get(params, "line_items")) and length(params["line_items"]) > 0 ->
                  Payments.partial_refund(order, params["line_items"], refund_opts)

                is_integer(Map.get(params, "amount_cents")) ->
                  Payments.partial_refund_by_amount(order, params["amount_cents"], refund_opts)

                true ->
                  {:error, :missing_partial_refund_params}
              end

            _ ->
              {:error, :invalid_refund_type}
          end

        handle_refund_result(conn, result)
    end
  end

  @doc """
  List all refunds for an order.

  GET /api/orders/:id/refunds
  """
  def index(conn, %{"order_id" => order_id}) do
    case Orders.get_order(order_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Order not found"})

      _order ->
        refunds = Payments.list_refunds(order_id)

        json(conn, %{
          data: Enum.map(refunds, &serialize_refund/1)
        })
    end
  end

  # --- Private ---

  defp handle_refund_result(conn, {:ok, %{order: order, refund: refund}}) do
    json(conn, %{
      data: %{
        order_id: order.id,
        status: order.status,
        refund_amount: order.refund_amount,
        refund_reason: order.refund_reason,
        refunded_at: order.refunded_at,
        refund: serialize_refund(refund)
      }
    })
  end

  defp handle_refund_result(conn, {:ok, %{order: order, refunds: refunds}}) do
    json(conn, %{
      data: %{
        order_id: order.id,
        status: order.status,
        refund_amount: order.refund_amount,
        refund_reason: order.refund_reason,
        refunded_at: order.refunded_at,
        refunds: Enum.map(refunds, &serialize_refund/1)
      }
    })
  end

  defp handle_refund_result(conn, {:error, {:stripe_error, message}}) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: "Refund error: #{message}"})
  end

  defp handle_refund_result(conn, {:error, {:exceeds_refundable_amount, details}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "Refund exceeds remaining refundable amount", details: details})
  end

  defp handle_refund_result(conn, {:error, {:not_refundable, status}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "Order cannot be refunded (status: #{status})"})
  end

  defp handle_refund_result(conn, {:error, {:invalid_line_items, ids}}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "Invalid line item IDs", invalid_ids: ids})
  end

  defp handle_refund_result(conn, {:error, reason}) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})
  end

  defp serialize_refund(%{} = refund) do
    %{
      id: refund.id,
      type: refund.type,
      amount: refund.amount,
      reason: refund.reason,
      stripe_refund_id: refund.stripe_refund_id,
      status: refund.status,
      initiated_by: refund.initiated_by,
      fee_refund_amount: refund.fee_refund_amount,
      order_item_id: refund.order_item_id,
      created_at: refund.inserted_at
    }
  end
end
