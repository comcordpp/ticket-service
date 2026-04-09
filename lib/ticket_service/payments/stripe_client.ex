defmodule TicketService.Payments.StripeClient do
  @moduledoc """
  Stripe API client wrapper.

  Wraps Stripe API calls for PaymentIntents, Refunds, Connect accounts,
  and webhook verification. Includes idempotency keys on all mutating calls.

  This module can be replaced with a mock in tests via application config:

      config :ticket_service, :stripe_client, TicketService.Payments.MockStripe
  """

  @doc "Create a Stripe PaymentIntent with optional Connect split payment params."
  def create_payment_intent(params) do
    attrs = %{
      amount: params.amount,
      currency: params.currency,
      automatic_payment_methods: %{enabled: true},
      metadata: params[:metadata] || %{}
    }

    # Add Connect split payment params when organizer has a connected account
    attrs =
      case params[:transfer_data] do
        %{destination: dest} when is_binary(dest) ->
          attrs
          |> Map.put(:transfer_data, %{destination: dest})
          |> Map.put(:application_fee_amount, params[:application_fee_amount])

        _ ->
          attrs
      end

    opts = idempotency_opts(params[:idempotency_key])

    Stripe.PaymentIntent.create(attrs, opts)
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

    opts = idempotency_opts(params[:idempotency_key])

    Stripe.Refund.create(attrs, opts)
  end

  @doc "Verify a Stripe webhook signature."
  def verify_webhook(payload, signature, secret) do
    Stripe.Webhook.construct_event(payload, signature, secret)
  end

  @doc "Create a Stripe Connect Express account."
  def create_connect_account(params) do
    opts = idempotency_opts(params[:idempotency_key])

    Stripe.Account.create(%{
      type: params.type,
      email: params[:email],
      capabilities: params[:capabilities] || %{},
      metadata: params[:metadata] || %{}
    }, opts)
  end

  @doc "Retrieve a Stripe Connect account."
  def retrieve_connect_account(account_id) do
    Stripe.Account.retrieve(account_id)
  end

  @doc "Create an account link for Stripe Connect onboarding."
  def create_account_link(params) do
    Stripe.AccountLink.create(%{
      account: params.account,
      type: params.type,
      refresh_url: params.refresh_url,
      return_url: params.return_url
    })
  end

  defp idempotency_opts(nil), do: []
  defp idempotency_opts(key), do: [idempotency_key: key]
end
