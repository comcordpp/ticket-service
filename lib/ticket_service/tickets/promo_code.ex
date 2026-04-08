defmodule TicketService.Tickets.PromoCode do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @discount_types ~w(percentage fixed)

  schema "promo_codes" do
    field :code, :string
    field :discount_type, :string
    field :discount_value, :decimal
    field :max_uses, :integer
    field :used_count, :integer, default: 0
    field :valid_from, :utc_datetime
    field :valid_until, :utc_datetime
    field :active, :boolean, default: true

    belongs_to :event, TicketService.Events.Event

    timestamps(type: :utc_datetime)
  end

  def changeset(promo_code, attrs) do
    promo_code
    |> cast(attrs, [:code, :discount_type, :discount_value, :max_uses, :valid_from, :valid_until, :active, :event_id])
    |> validate_required([:code, :discount_type, :discount_value, :event_id])
    |> validate_inclusion(:discount_type, @discount_types)
    |> validate_number(:discount_value, greater_than: 0)
    |> validate_percentage()
    |> unique_constraint([:event_id, :code])
    |> foreign_key_constraint(:event_id)
  end

  defp validate_percentage(changeset) do
    if get_field(changeset, :discount_type) == "percentage" do
      validate_number(changeset, :discount_value, less_than_or_equal_to: 100)
    else
      changeset
    end
  end

  def discount_types, do: @discount_types
end
