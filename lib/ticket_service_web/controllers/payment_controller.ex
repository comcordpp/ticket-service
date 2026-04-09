defmodule TicketServiceWeb.PaymentController do
  use TicketServiceWeb, :controller

  alias TicketService.Orders
  alias TicketService.Payments
  alias TicketService.ETickets
  alias TicketService.Notifications
  alias TicketService.Repo

  @doc """
  Create a Stripe PaymentIntent for an order.

  POST /api/orders/token/:token/pay
  Body: { "email": "buyer@example.com", "name": "John Doe" }
  """
  def create_intent(conn, %{"token" => token} = params) do
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
  Body: { "reason": "requested_by_customer", "amount_cents": 5000 (optional for partial) }
  """
  def refund(conn, %{"id" => id} = params) do
    case Orders.get_order(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Order not found"})

      %{status: status} when status not in ["confirmed", "partially_refunded"] ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Order cannot be refunded (status: #{status})"})

      order ->
        reason = Map.get(params, "reason", "requested_by_customer")

        result =
          case Map.get(params, "amount_cents") do
            nil -> Payments.refund_order(order, reason: reason)
            amount -> Payments.partial_refund(order, amount, reason: reason)
          end

        case result do
          {:ok, refunded_order} ->
            # Cancel e-tickets on full refund
            if refunded_order.status == "refunded" do
              ETickets.cancel_tickets_for_order(refunded_order.id)
            end

            json(conn, %{
              data: %{
                order_id: refunded_order.id,
                status: refunded_order.status,
                refund_amount: refunded_order.refund_amount,
                refund_reason: refunded_order.refund_reason,
                refunded_at: refunded_order.refunded_at
              }
            })

          {:error, {:stripe_error, message}} ->
            conn |> put_status(:unprocessable_entity) |> json(%{error: "Refund error: #{message}"})

          {:error, reason} ->
            conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})
        end
    end
  end
end
