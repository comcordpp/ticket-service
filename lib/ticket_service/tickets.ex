defmodule TicketService.Tickets do
  @moduledoc """
  The Tickets context — manages ticket types and promo codes.
  """
  import Ecto.Query
  alias TicketService.Repo
  alias TicketService.Tickets.{TicketType, PromoCode}

  # Ticket Types

  def list_ticket_types(event_id) do
    TicketType
    |> where([t], t.event_id == ^event_id)
    |> order_by([t], asc: t.name)
    |> Repo.all()
  end

  def get_ticket_type(id), do: Repo.get(TicketType, id)

  def get_ticket_type!(id), do: Repo.get!(TicketType, id)

  def create_ticket_type(attrs) do
    %TicketType{}
    |> TicketType.changeset(attrs)
    |> Repo.insert()
  end

  def update_ticket_type(%TicketType{} = ticket_type, attrs) do
    ticket_type
    |> TicketType.changeset(attrs)
    |> Repo.update()
  end

  def delete_ticket_type(%TicketType{} = ticket_type) do
    Repo.delete(ticket_type)
  end

  # Promo Codes

  def list_promo_codes(event_id) do
    PromoCode
    |> where([p], p.event_id == ^event_id)
    |> order_by([p], asc: p.code)
    |> Repo.all()
  end

  def get_promo_code(id), do: Repo.get(PromoCode, id)

  def get_promo_code_by_code(event_id, code) do
    PromoCode
    |> where([p], p.event_id == ^event_id and p.code == ^code)
    |> Repo.one()
  end

  def create_promo_code(attrs) do
    %PromoCode{}
    |> PromoCode.changeset(attrs)
    |> Repo.insert()
  end

  def update_promo_code(%PromoCode{} = promo_code, attrs) do
    promo_code
    |> PromoCode.changeset(attrs)
    |> Repo.update()
  end

  def delete_promo_code(%PromoCode{} = promo_code) do
    Repo.delete(promo_code)
  end

  def validate_promo_code(event_id, code) do
    now = DateTime.utc_now()

    case get_promo_code_by_code(event_id, code) do
      nil ->
        {:error, :not_found}

      %PromoCode{active: false} ->
        {:error, :inactive}

      %PromoCode{max_uses: max, used_count: used} when not is_nil(max) and used >= max ->
        {:error, :exhausted}

      %PromoCode{valid_from: from} when not is_nil(from) ->
        if DateTime.compare(now, from) == :lt, do: {:error, :not_yet_valid}, else: check_expiry(get_promo_code_by_code(event_id, code), now)

      promo ->
        check_expiry(promo, now)
    end
  end

  defp check_expiry(%PromoCode{valid_until: nil} = promo, _now), do: {:ok, promo}
  defp check_expiry(%PromoCode{valid_until: until} = promo, now) do
    if DateTime.compare(now, until) == :gt, do: {:error, :expired}, else: {:ok, promo}
  end
end
