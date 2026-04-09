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
    |> Repo.preload([:venue, :ticket_types, :organizer, venue: :sections])
  end

  def create_event(attrs) do
    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert()
  end

  def update_event(%Event{status: "cancelled"}, _attrs) do
    {:error, :event_cancelled}
  end

  def update_event(%Event{} = event, attrs) do
    if event.status == "published" and TicketService.Orders.event_has_sales?(event.id) do
      event
      |> Event.edit_with_sales_changeset(attrs)
      |> Repo.update()
    else
      event
      |> Event.changeset(attrs)
      |> Repo.update()
    end
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

  def cancel_event(%Event{status: "cancelled"}) do
    {:error, :already_cancelled}
  end

  def cancel_event(%Event{} = event) do
    alias TicketService.Orders
    alias TicketService.Orders.Order

    Repo.transaction(fn ->
      # Cancel the event
      {:ok, cancelled} =
        event
        |> Ecto.Changeset.change(status: "cancelled")
        |> Repo.update()

      # Batch refund all confirmed orders for this event
      confirmed_orders =
        Order
        |> where([o], o.event_id == ^event.id and o.status == "confirmed")
        |> Repo.all()
        |> Repo.preload(:order_items)

      Enum.each(confirmed_orders, fn order ->
        Orders.cancel_order(order)
      end)

      # Also cancel pending orders
      pending_orders =
        Order
        |> where([o], o.event_id == ^event.id and o.status == "pending")
        |> Repo.all()
        |> Repo.preload(:order_items)

      Enum.each(pending_orders, fn order ->
        Orders.cancel_order(order)
      end)

      cancelled
    end)
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
