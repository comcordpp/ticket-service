defmodule TicketServiceWeb.PromoCodeController do
  use TicketServiceWeb, :controller

  alias TicketService.Tickets

  def index(conn, %{"event_id" => event_id}) do
    promo_codes = Tickets.list_promo_codes(event_id)
    json(conn, %{data: Enum.map(promo_codes, &promo_code_json/1)})
  end

  def create(conn, %{"event_id" => event_id, "promo_code" => pc_params}) do
    attrs = Map.put(pc_params, "event_id", event_id)

    case Tickets.create_promo_code(attrs) do
      {:ok, promo_code} ->
        conn
        |> put_status(:created)
        |> json(%{data: promo_code_json(promo_code)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def show(conn, %{"id" => id}) do
    case Tickets.get_promo_code(id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "Promo code not found"})
      pc -> json(conn, %{data: promo_code_json(pc)})
    end
  end

  def update(conn, %{"id" => id, "promo_code" => pc_params}) do
    promo_code = Tickets.get_promo_code!(id)

    case Tickets.update_promo_code(promo_code, pc_params) do
      {:ok, pc} -> json(conn, %{data: promo_code_json(pc)})
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def delete(conn, %{"id" => id}) do
    promo_code = Tickets.get_promo_code!(id)

    case Tickets.delete_promo_code(promo_code) do
      {:ok, _} -> send_resp(conn, :no_content, "")
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def validate(conn, %{"event_id" => event_id, "code" => code}) do
    case Tickets.validate_promo_code(event_id, code) do
      {:ok, promo} ->
        json(conn, %{data: %{valid: true, discount_type: promo.discount_type, discount_value: promo.discount_value}})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{data: %{valid: false, reason: to_string(reason)}})
    end
  end

  defp promo_code_json(pc) do
    %{
      id: pc.id,
      code: pc.code,
      discount_type: pc.discount_type,
      discount_value: pc.discount_value,
      max_uses: pc.max_uses,
      used_count: pc.used_count,
      valid_from: pc.valid_from,
      valid_until: pc.valid_until,
      active: pc.active,
      event_id: pc.event_id,
      inserted_at: pc.inserted_at,
      updated_at: pc.updated_at
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
