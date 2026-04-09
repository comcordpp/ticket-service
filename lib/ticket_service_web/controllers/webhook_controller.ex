defmodule TicketServiceWeb.WebhookController do
  use TicketServiceWeb, :controller

  alias TicketService.Payments

  require Logger

  @doc """
  Handle incoming Stripe webhook events.

  Verifies the webhook signature, then delegates to the Payments context.
  """
  def stripe(conn, _params) do
    signature = get_req_header(conn, "stripe-signature") |> List.first()
    webhook_secret = Application.get_env(:ticket_service, :stripe_webhook_secret)

    with {:ok, payload} <- read_raw_body(conn),
         {:ok, event} <- Payments.verify_webhook_signature(payload, signature, webhook_secret) do
      case Payments.handle_webhook_event(event) do
        {:ok, _} ->
          json(conn, %{status: "ok"})

        {:ok, :ignored, type} ->
          Logger.debug("Ignored Stripe event: #{type}")
          json(conn, %{status: "ok"})

        {:error, reason} ->
          Logger.warning("Webhook processing failed: #{inspect(reason)}")
          conn |> put_status(:unprocessable_entity) |> json(%{error: "processing_failed"})
      end
    else
      {:error, :invalid_signature} ->
        conn |> put_status(:bad_request) |> json(%{error: "invalid_signature"})

      {:error, reason} ->
        Logger.warning("Webhook verification failed: #{inspect(reason)}")
        conn |> put_status(:bad_request) |> json(%{error: "verification_failed"})
    end
  end

  defp read_raw_body(conn) do
    case conn.assigns[:raw_body] do
      nil -> {:error, :no_raw_body}
      body -> {:ok, body}
    end
  end
end
