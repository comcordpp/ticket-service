defmodule TicketService.Venues.Venue do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "venues" do
    field :name, :string
    field :address, :string
    field :capacity, :integer

    has_many :sections, TicketService.Seating.Section
    has_many :events, TicketService.Events.Event

    timestamps(type: :utc_datetime)
  end

  def changeset(venue, attrs) do
    venue
    |> cast(attrs, [:name, :address, :capacity])
    |> validate_required([:name, :capacity])
    |> validate_number(:capacity, greater_than: 0)
  end
end
