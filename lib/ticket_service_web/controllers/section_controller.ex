defmodule TicketServiceWeb.SectionController do
  use TicketServiceWeb, :controller

  alias TicketService.Seating

  def index(conn, %{"venue_id" => venue_id}) do
    sections = Seating.list_sections(venue_id)
    json(conn, %{data: Enum.map(sections, &section_json/1)})
  end

  def create(conn, %{"venue_id" => venue_id, "section" => section_params}) do
    attrs = Map.put(section_params, "venue_id", venue_id)

    case Seating.create_section(attrs) do
      {:ok, section} ->
        conn
        |> put_status(:created)
        |> json(%{data: section_detail_json(section)})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def show(conn, %{"id" => id}) do
    case Seating.get_section_with_seats(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Section not found"})

      section ->
        json(conn, %{data: section_detail_json(section)})
    end
  end

  def update(conn, %{"id" => id, "section" => section_params}) do
    section = Seating.get_section!(id)

    case Seating.update_section(section, section_params) do
      {:ok, section} -> json(conn, %{data: section_json(section)})
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def delete(conn, %{"id" => id}) do
    section = Seating.get_section!(id)

    case Seating.delete_section(section) do
      {:ok, _} -> send_resp(conn, :no_content, "")
      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: format_errors(changeset)})
    end
  end

  def seats(conn, %{"section_id" => section_id}) do
    seats = Seating.list_seats(section_id)
    json(conn, %{data: Enum.map(seats, &seat_json/1)})
  end

  defp section_json(section) do
    %{
      id: section.id,
      name: section.name,
      type: section.type,
      capacity: section.capacity,
      row_count: section.row_count,
      seats_per_row: section.seats_per_row,
      venue_id: section.venue_id
    }
  end

  defp section_detail_json(section) do
    section_json(section)
    |> Map.put(:seats, Enum.map(section.seats || [], &seat_json/1))
  end

  defp seat_json(seat) do
    %{
      id: seat.id,
      row_label: seat.row_label,
      seat_number: seat.seat_number,
      status: seat.status
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
