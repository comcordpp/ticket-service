defmodule TicketService.Events do
  @moduledoc """
  The Events context — manages event lifecycle (create, update, publish, cancel).
  """
  import Ecto.Query
  alias TicketService.Repo
  alias TicketService.Events.Event

  def list_events(filters \\ %{}) do
    Event
    |> apply_filters(filters)
    |> order_by([e], desc: e.starts_at)
    |> Repo.all()
  end

  def get_event(id), do: Repo.get(Event, id)

  def get_event!(id), do: Repo.get!(Event, id)

  def get_event_with_details(id) do
    Event
    |> Repo.get(id)
    |> Repo.preload([:venue, :ticket_types, venue: :sections])
  end

  def create_event(attrs) do
    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert()
  end

  def update_event(%Event{} = event, attrs) do
    event
    |> Event.changeset(attrs)
    |> Repo.update()
  end

  def delete_event(%Event{} = event) do
    Repo.delete(event)
  end

  def publish_event(%Event{} = event) do
    ticket_types = Repo.preload(event, :ticket_types).ticket_types

    if Enum.empty?(ticket_types) do
      {:error, :no_ticket_types}
    else
      event
      |> Event.publish_changeset()
      |> Repo.update()
    end
  end

  def cancel_event(%Event{} = event) do
    event
    |> Ecto.Changeset.change(status: "cancelled")
    |> Repo.update()
  end

  def list_published_events do
    Event
    |> where([e], e.status == "published")
    |> order_by([e], asc: e.starts_at)
    |> Repo.all()
  end

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:status, status}, q -> where(q, [e], e.status == ^status)
      {:category, cat}, q -> where(q, [e], e.category == ^cat)
      {:venue_id, vid}, q -> where(q, [e], e.venue_id == ^vid)
      _, q -> q
    end)
  end
end
