defmodule TicketService.Occupancy.Snapshot do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "occupancy_snapshots" do
    field :count, :integer, default: 0

    belongs_to :venue, TicketService.Venues.Venue
    belongs_to :section, TicketService.Seating.Section

    timestamps(type: :utc_datetime)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [:venue_id, :section_id, :count])
    |> validate_required([:venue_id, :section_id, :count])
    |> validate_number(:count, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:venue_id)
    |> foreign_key_constraint(:section_id)
  end
end
