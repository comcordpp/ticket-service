defmodule TicketService.Seating.Seat do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(available held sold)

  schema "seats" do
    field :row_label, :string
    field :seat_number, :integer
    field :status, :string, default: "available"
    field :lock_version, :integer, default: 1

    belongs_to :section, TicketService.Seating.Section

    timestamps(type: :utc_datetime)
  end

  def changeset(seat, attrs) do
    seat
    |> cast(attrs, [:row_label, :seat_number, :status, :section_id])
    |> validate_required([:row_label, :seat_number, :section_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:seat_number, greater_than: 0)
    |> foreign_key_constraint(:section_id)
    |> unique_constraint([:section_id, :row_label, :seat_number])
  end

  @doc "Changeset for status transitions with optimistic locking."
  def status_changeset(seat, new_status) do
    seat
    |> cast(%{status: new_status}, [:status])
    |> validate_inclusion(:status, @statuses)
    |> optimistic_lock(:lock_version)
  end

  def statuses, do: @statuses
end
