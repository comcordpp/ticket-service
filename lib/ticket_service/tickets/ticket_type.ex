defmodule TicketService.Tickets.TicketType do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "ticket_types" do
    field :name, :string
    field :price, :decimal
    field :quantity, :integer
    field :sold_count, :integer, default: 0
    field :sale_starts_at, :utc_datetime
    field :sale_ends_at, :utc_datetime

    belongs_to :event, TicketService.Events.Event

    timestamps(type: :utc_datetime)
  end

  def changeset(ticket_type, attrs) do
    ticket_type
    |> cast(attrs, [:name, :price, :quantity, :sale_starts_at, :sale_ends_at, :event_id])
    |> validate_required([:name, :price, :quantity, :event_id])
    |> validate_number(:price, greater_than_or_equal_to: 0)
    |> validate_number(:quantity, greater_than: 0)
    |> validate_sale_window()
    |> foreign_key_constraint(:event_id)
  end

  @doc "Changeset that locks price and quantity when the event has sales."
  def locked_changeset(ticket_type, attrs) do
    locked_fields = [:price, :quantity]

    changeset =
      ticket_type
      |> cast(attrs, [:name, :price, :quantity, :sale_starts_at, :sale_ends_at])
      |> validate_required([:name, :price, :quantity, :event_id])
      |> validate_number(:price, greater_than_or_equal_to: 0)
      |> validate_number(:quantity, greater_than: 0)
      |> validate_sale_window()

    Enum.reduce(locked_fields, changeset, fn field, cs ->
      if get_change(cs, field) != nil do
        add_error(cs, field, "cannot be changed after tickets have been sold")
      else
        cs
      end
    end)
  end

  defp validate_sale_window(changeset) do
    case {get_field(changeset, :sale_starts_at), get_field(changeset, :sale_ends_at)} do
      {starts, ends} when not is_nil(starts) and not is_nil(ends) ->
        if DateTime.compare(ends, starts) == :gt do
          changeset
        else
          add_error(changeset, :sale_ends_at, "must be after sale start time")
        end

      _ ->
        changeset
    end
  end
end
