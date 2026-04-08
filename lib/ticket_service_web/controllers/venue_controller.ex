defmodule TicketServiceWeb.VenueController do
  use TicketServiceWeb, :controller

  alias TicketService.Venues

  def index(conn, _params) do
    venues = Venues.list_venues()
    json(conn, %{data: Enum.map(venues, &venue_json/1)})
  end

  def create(conn, %{"venue" => venue_params}) do
    case Venues.create_venue(venue_params) do
      {:ok, venue} ->
        conn
        |> put_status(:created)
        |> json(%{data: venue_json(venue)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def show(conn, %{"id" => id}) do
    case Venues.get_venue_with_sections(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Venue not found"})

      venue ->
        json(conn, %{data: venue_detail_json(venue)})
    end
  end

  def update(conn, %{"id" => id, "venue" => venue_params}) do
    venue = Venues.get_venue!(id)

    case Venues.update_venue(venue, venue_params) do
      {:ok, venue} -> json(conn, %{data: venue_json(venue)})
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def delete(conn, %{"id" => id}) do
    venue = Venues.get_venue!(id)

    case Venues.delete_venue(venue) do
      {:ok, _} -> send_resp(conn, :no_content, "")
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  defp venue_json(venue) do
    %{
      id: venue.id,
      name: venue.name,
      address: venue.address,
      capacity: venue.capacity,
      inserted_at: venue.inserted_at,
      updated_at: venue.updated_at
    }
  end

  defp venue_detail_json(venue) do
    venue_json(venue)
    |> Map.put(:sections, Enum.map(venue.sections || [], &section_json/1))
  end

  defp section_json(section) do
    %{
      id: section.id,
      name: section.name,
      type: section.type,
      capacity: section.capacity,
      row_count: section.row_count,
      seats_per_row: section.seats_per_row,
      seat_count: length(section.seats || [])
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
