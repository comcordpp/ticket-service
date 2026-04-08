defmodule TicketService.Venues do
  @moduledoc """
  The Venues context — manages venue CRUD and capacity enforcement.
  """
  import Ecto.Query
  alias TicketService.Repo
  alias TicketService.Venues.Venue

  def list_venues do
    Venue
    |> order_by([v], asc: v.name)
    |> Repo.all()
  end

  def get_venue(id), do: Repo.get(Venue, id)

  def get_venue!(id), do: Repo.get!(Venue, id)

  def get_venue_with_sections(id) do
    Venue
    |> Repo.get(id)
    |> Repo.preload(sections: :seats)
  end

  def create_venue(attrs) do
    %Venue{}
    |> Venue.changeset(attrs)
    |> Repo.insert()
  end

  def update_venue(%Venue{} = venue, attrs) do
    venue
    |> Venue.changeset(attrs)
    |> Repo.update()
  end

  def delete_venue(%Venue{} = venue) do
    Repo.delete(venue)
  end
end
