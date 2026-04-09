defmodule TicketServiceWeb.OrganizerController do
  use TicketServiceWeb, :controller

  alias TicketService.Organizers

  def index(conn, _params) do
    organizers = Organizers.list_organizers()
    json(conn, %{data: Enum.map(organizers, &organizer_json/1)})
  end

  def create(conn, params) do
    case Organizers.create_organizer(params) do
      {:ok, organizer} ->
        conn
        |> put_status(:created)
        |> json(%{data: organizer_json(organizer)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def show(conn, %{"id" => id}) do
    case Organizers.get_organizer(id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "Organizer not found"})
      organizer -> json(conn, %{data: organizer_json(organizer)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    case Organizers.get_organizer(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Organizer not found"})

      organizer ->
        case Organizers.update_organizer(organizer, params) do
          {:ok, updated} -> json(conn, %{data: organizer_json(updated)})
          {:error, changeset} ->
            conn |> put_status(:unprocessable_entity) |> json(%{errors: format_errors(changeset)})
        end
    end
  end

  @doc """
  Create a Stripe Connect Express account for an organizer.

  POST /api/organizers/:id/connect
  """
  def create_connect_account(conn, %{"id" => id}) do
    case Organizers.get_organizer(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Organizer not found"})

      organizer ->
        case Organizers.create_connect_account(organizer) do
          {:ok, updated} ->
            # Generate onboarding link immediately
            case Organizers.create_account_link(updated) do
              {:ok, %{url: url}} ->
                conn
                |> put_status(:created)
                |> json(%{data: %{organizer: organizer_json(updated), onboarding_url: url}})

              {:error, _} ->
                conn
                |> put_status(:created)
                |> json(%{data: organizer_json(updated)})
            end

          {:error, :account_already_exists} ->
            conn |> put_status(:conflict) |> json(%{error: "Stripe account already exists"})

          {:error, {:stripe_error, message}} ->
            conn |> put_status(:unprocessable_entity) |> json(%{error: "Stripe error: #{message}"})
        end
    end
  end

  @doc """
  Generate a new onboarding link for an organizer's Stripe Connect account.

  POST /api/organizers/:id/onboarding-link
  """
  def onboarding_link(conn, %{"id" => id}) do
    case Organizers.get_organizer(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Organizer not found"})

      organizer ->
        case Organizers.create_account_link(organizer) do
          {:ok, %{url: url}} ->
            json(conn, %{data: %{url: url}})

          {:error, :no_stripe_account} ->
            conn |> put_status(:unprocessable_entity) |> json(%{error: "No Stripe account. Create one first via POST /organizers/:id/connect"})

          {:error, {:stripe_error, message}} ->
            conn |> put_status(:unprocessable_entity) |> json(%{error: "Stripe error: #{message}"})
        end
    end
  end

  @doc """
  Refresh the organizer's Stripe account status.

  POST /api/organizers/:id/refresh-status
  """
  def refresh_status(conn, %{"id" => id}) do
    case Organizers.get_organizer(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Organizer not found"})

      organizer ->
        case Organizers.refresh_account_status(organizer) do
          {:ok, updated} -> json(conn, %{data: organizer_json(updated)})

          {:error, :no_stripe_account} ->
            conn |> put_status(:unprocessable_entity) |> json(%{error: "No Stripe account"})

          {:error, {:stripe_error, message}} ->
            conn |> put_status(:unprocessable_entity) |> json(%{error: "Stripe error: #{message}"})
        end
    end
  end

  defp organizer_json(organizer) do
    %{
      id: organizer.id,
      name: organizer.name,
      email: organizer.email,
      stripe_account_id: organizer.stripe_account_id,
      stripe_onboarding_complete: organizer.stripe_onboarding_complete,
      stripe_charges_enabled: organizer.stripe_charges_enabled,
      stripe_payouts_enabled: organizer.stripe_payouts_enabled,
      inserted_at: organizer.inserted_at,
      updated_at: organizer.updated_at
    }
  end

  defp format_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
