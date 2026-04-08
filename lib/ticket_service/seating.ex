defmodule TicketService.Seating do
  @moduledoc """
  The Seating context — manages sections and seat grids for venues.
  """
  import Ecto.Query
  alias TicketService.Repo
  alias TicketService.Seating.{Section, Seat}

  def list_sections(venue_id) do
    Section
    |> where([s], s.venue_id == ^venue_id)
    |> order_by([s], asc: s.name)
    |> Repo.all()
  end

  def get_section(id), do: Repo.get(Section, id)

  def get_section!(id), do: Repo.get!(Section, id)

  def get_section_with_seats(id) do
    Section
    |> Repo.get(id)
    |> Repo.preload(:seats)
  end

  def create_section(attrs) do
    result =
      %Section{}
      |> Section.changeset(attrs)
      |> Repo.insert()

    case result do
      {:ok, section} ->
        if section.type in ["reserved", "vip"] do
          generate_seats(section)
        end

        {:ok, Repo.preload(section, :seats)}

      error ->
        error
    end
  end

  def update_section(%Section{} = section, attrs) do
    section
    |> Section.changeset(attrs)
    |> Repo.update()
  end

  def delete_section(%Section{} = section) do
    Repo.delete(section)
  end

  def list_seats(section_id) do
    Seat
    |> where([s], s.section_id == ^section_id)
    |> order_by([s], asc: s.row_label, asc: s.seat_number)
    |> Repo.all()
  end

  defp generate_seats(%Section{} = section) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    seats =
      for row <- 1..section.row_count,
          seat_num <- 1..section.seats_per_row do
        %{
          section_id: section.id,
          row_label: row_label(row),
          seat_number: seat_num,
          status: "available",
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all(Seat, seats)
  end

  defp row_label(num) when num <= 26, do: <<(num + 64)>>
  defp row_label(num), do: "#{<<(div(num - 1, 26) + 64)>>}#{<<(rem(num - 1, 26) + 65)>>}"
end
