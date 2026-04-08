defmodule TicketServiceWeb.TicketTypeController do
  use TicketServiceWeb, :controller

  alias TicketService.Tickets

  def index(conn, %{"event_id" => event_id}) do
    ticket_types = Tickets.list_ticket_types(event_id)
    json(conn, %{data: Enum.map(ticket_types, &ticket_type_json/1)})
  end

  def create(conn, %{"event_id" => event_id, "ticket_type" => tt_params}) do
    attrs = Map.put(tt_params, "event_id", event_id)

    case Tickets.create_ticket_type(attrs) do
      {:ok, ticket_type} ->
        conn
        |> put_status(:created)
        |> json(%{data: ticket_type_json(ticket_type)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def show(conn, %{"id" => id}) do
    case Tickets.get_ticket_type(id) do
      nil -> conn |> put_status(:not_found) |> json(%{error: "Ticket type not found"})
      tt -> json(conn, %{data: ticket_type_json(tt)})
    end
  end

  def update(conn, %{"id" => id, "ticket_type" => tt_params}) do
    ticket_type = Tickets.get_ticket_type!(id)

    case Tickets.update_ticket_type(ticket_type, tt_params) do
      {:ok, tt} -> json(conn, %{data: ticket_type_json(tt)})
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def delete(conn, %{"id" => id}) do
    ticket_type = Tickets.get_ticket_type!(id)

    case Tickets.delete_ticket_type(ticket_type) do
      {:ok, _} -> send_resp(conn, :no_content, "")
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  defp ticket_type_json(tt) do
    %{
      id: tt.id,
      name: tt.name,
      price: tt.price,
      quantity: tt.quantity,
      sold_count: tt.sold_count,
      sale_starts_at: tt.sale_starts_at,
      sale_ends_at: tt.sale_ends_at,
      event_id: tt.event_id,
      inserted_at: tt.inserted_at,
      updated_at: tt.updated_at
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
