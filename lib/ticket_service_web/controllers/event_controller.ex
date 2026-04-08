defmodule TicketServiceWeb.EventController do
  use TicketServiceWeb, :controller

  alias TicketService.Events

  def index(conn, params) do
    filters =
      params
      |> Map.take(["status", "category", "venue_id"])
      |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
      |> Map.new()

    events = Events.list_events(filters)
    json(conn, %{data: Enum.map(events, &event_json/1)})
  end

  def create(conn, %{"event" => event_params}) do
    case Events.create_event(event_params) do
      {:ok, event} ->
        conn
        |> put_status(:created)
        |> json(%{data: event_json(event)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def show(conn, %{"id" => id}) do
    case Events.get_event_with_details(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Event not found"})

      event ->
        json(conn, %{data: event_detail_json(event)})
    end
  end

  def update(conn, %{"id" => id, "event" => event_params}) do
    event = Events.get_event!(id)

    case Events.update_event(event, event_params) do
      {:ok, event} ->
        json(conn, %{data: event_json(event)})

      {:error, :event_cancelled} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Cannot edit a cancelled event"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def delete(conn, %{"id" => id}) do
    event = Events.get_event!(id)

    case Events.delete_event(event) do
      {:ok, _} -> send_resp(conn, :no_content, "")
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def publish(conn, %{"id" => id}) do
    event = Events.get_event!(id)

    case Events.publish_event(event) do
      {:ok, event} ->
        json(conn, %{data: event_json(event)})

      {:error, :no_ticket_types} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Cannot publish event without at least one ticket type"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def cancel(conn, %{"id" => id}) do
    event = Events.get_event!(id)

    case Events.cancel_event(event) do
      {:ok, event} -> json(conn, %{data: event_json(event)})

      {:error, :already_cancelled} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "Event is already cancelled"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  defp event_json(event) do
    %{
      id: event.id,
      title: event.title,
      description: event.description,
      category: event.category,
      status: event.status,
      starts_at: event.starts_at,
      ends_at: event.ends_at,
      venue_id: event.venue_id,
      inserted_at: event.inserted_at,
      updated_at: event.updated_at
    }
  end

  defp event_detail_json(event) do
    event_json(event)
    |> Map.merge(%{
      venue: if(event.venue, do: venue_json(event.venue)),
      ticket_types: Enum.map(event.ticket_types || [], &ticket_type_json/1)
    })
  end

  defp venue_json(venue) do
    %{id: venue.id, name: venue.name, address: venue.address, capacity: venue.capacity}
  end

  defp ticket_type_json(tt) do
    %{
      id: tt.id, name: tt.name, price: tt.price, quantity: tt.quantity,
      sold_count: tt.sold_count, sale_starts_at: tt.sale_starts_at, sale_ends_at: tt.sale_ends_at
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
