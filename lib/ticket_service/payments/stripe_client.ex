defmodule TicketService.Payments.StripeClient do
  @moduledoc """
  Stripe API client wrapper.

  Wraps Stripe API calls for PaymentIntents, Refunds, and webhook verification.
  This module can be replaced with a mock in tests via application config:

      config :ticket_service, :stripe_client, TicketService.Payments.MockStripe
  """

  @doc "Create a Stripe PaymentIntent."
  def create_payment_intent(params) do
    Stripe.PaymentIntent.create(%{
      amount: params.amount,
      currency: params.currency,
      automatic_payment_methods: %{enabled: true},
      metadata: params[:metadata] || %{}
    })
  end

  @doc "Create a Stripe Refund."
  def create_refund(params) do
    attrs = %{
      payment_intent: params.payment_intent,
      reason: params[:reason] || "requested_by_customer"
    }

    attrs =
      if params[:amount] do
        Map.put(attrs, :amount, params.amount)
      else
        attrs
      end

    Stripe.Refund.create(attrs)
  end

  @doc "Verify a Stripe webhook signature."
  def verify_webhook(payload, signature, secret) do
    Stripe.Webhook.construct_event(payload, signature, secret)
  end
end
