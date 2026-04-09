defmodule TicketService.Payments.MockStripe do
  @moduledoc "Mock Stripe client for testing."

  def create_payment_intent(params) do
    {:ok, %{
      id: "pi_test_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}",
      client_secret: "pi_test_secret_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}",
      amount: params.amount,
      currency: params.currency,
      status: "requires_payment_method"
    }}
  end

  def create_refund(params) do
    amount = params[:amount] || params[:original_amount] || 5000

    {:ok, %{
      id: "re_test_#{:crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)}",
      amount: amount,
      payment_intent: params.payment_intent,
      status: "succeeded",
      reverse_transfer: params[:reverse_transfer] || false,
      refund_application_fee: params[:refund_application_fee] || false
    }}
  end

  def verify_webhook(payload, _signature, _secret) do
    case Jason.decode(payload) do
      {:ok, event} -> {:ok, event}
      _ -> {:error, :invalid_signature}
    end
  end
end
