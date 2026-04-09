defmodule TicketService.Organizers do
  @moduledoc """
  The Organizers context — manages organizer accounts and Stripe Connect onboarding.
  """
  import Ecto.Query
  alias TicketService.Repo
  alias TicketService.Organizers.Organizer

  def list_organizers do
    Organizer
    |> order_by([o], desc: o.inserted_at)
    |> Repo.all()
  end

  def get_organizer(id), do: Repo.get(Organizer, id)

  def get_organizer!(id), do: Repo.get!(Organizer, id)

  def create_organizer(attrs) do
    %Organizer{}
    |> Organizer.changeset(attrs)
    |> Repo.insert()
  end

  def update_organizer(%Organizer{} = organizer, attrs) do
    organizer
    |> Organizer.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Create a Stripe Connect Express account for an organizer and return
  an account link URL for onboarding.
  """
  def create_connect_account(%Organizer{stripe_account_id: nil} = organizer) do
    account_params = %{
      type: "express",
      email: organizer.email,
      capabilities: %{
        card_payments: %{requested: true},
        transfers: %{requested: true}
      },
      metadata: %{organizer_id: organizer.id}
    }

    with {:ok, account} <- stripe_client().create_connect_account(account_params),
         {:ok, updated} <- update_organizer(organizer, %{stripe_account_id: account.id}) do
      {:ok, updated}
    end
  end

  def create_connect_account(%Organizer{stripe_account_id: _id}) do
    {:error, :account_already_exists}
  end

  @doc """
  Generate an onboarding link for an organizer's Stripe Connect account.
  """
  def create_account_link(%Organizer{stripe_account_id: nil}) do
    {:error, :no_stripe_account}
  end

  def create_account_link(%Organizer{stripe_account_id: account_id} = organizer) do
    base_url = Application.get_env(:ticket_service, :base_url)

    link_params = %{
      account: account_id,
      type: "account_onboarding",
      refresh_url: "#{base_url}/api/organizers/#{organizer.id}/onboarding/refresh",
      return_url: "#{base_url}/api/organizers/#{organizer.id}/onboarding/complete"
    }

    stripe_client().create_account_link(link_params)
  end

  @doc """
  Refresh the organizer's Stripe account status from the Stripe API.
  """
  def refresh_account_status(%Organizer{stripe_account_id: nil}) do
    {:error, :no_stripe_account}
  end

  def refresh_account_status(%Organizer{stripe_account_id: account_id} = organizer) do
    case stripe_client().retrieve_connect_account(account_id) do
      {:ok, account} ->
        update_organizer(organizer, %{
          stripe_onboarding_complete: account.details_submitted,
          stripe_charges_enabled: account.charges_enabled,
          stripe_payouts_enabled: account.payouts_enabled
        })

      {:error, reason} ->
        {:error, {:stripe_error, reason}}
    end
  end

  defp stripe_client do
    Application.get_env(:ticket_service, :stripe_client, TicketService.Payments.StripeClient)
  end
end
