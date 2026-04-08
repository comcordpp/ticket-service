defmodule TicketService.Seating.Section do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @section_types ~w(general_admission reserved vip)

  schema "sections" do
    field :name, :string
    field :type, :string
    field :capacity, :integer
    field :row_count, :integer
    field :seats_per_row, :integer

    belongs_to :venue, TicketService.Venues.Venue
    has_many :seats, TicketService.Seating.Seat

    timestamps(type: :utc_datetime)
  end

  def changeset(section, attrs) do
    section
    |> cast(attrs, [:name, :type, :capacity, :row_count, :seats_per_row, :venue_id])
    |> validate_required([:name, :type, :capacity, :venue_id])
    |> validate_inclusion(:type, @section_types)
    |> validate_number(:capacity, greater_than: 0)
    |> validate_reserved_seating()
    |> foreign_key_constraint(:venue_id)
  end

  defp validate_reserved_seating(changeset) do
    type = get_field(changeset, :type)

    if type in ["reserved", "vip"] do
      changeset
      |> validate_required([:row_count, :seats_per_row])
      |> validate_number(:row_count, greater_than: 0)
      |> validate_number(:seats_per_row, greater_than: 0)
    else
      changeset
    end
  end

  def section_types, do: @section_types
end
