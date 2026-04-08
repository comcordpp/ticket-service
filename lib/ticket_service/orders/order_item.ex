defmodule TicketService.Orders.OrderItem do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "order_items" do
    field :quantity, :integer
    field :unit_price, :decimal
    field :seat_ids, {:array, :binary_id}, default: []

    belongs_to :order, TicketService.Orders.Order
    belongs_to :ticket_type, TicketService.Tickets.TicketType

    timestamps(type: :utc_datetime)
  end

  def changeset(order_item, attrs) do
    order_item
    |> cast(attrs, [:quantity, :unit_price, :seat_ids, :order_id, :ticket_type_id])
    |> validate_required([:quantity, :unit_price, :order_id, :ticket_type_id])
    |> validate_number(:quantity, greater_than: 0)
    |> validate_number(:unit_price, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:order_id)
    |> foreign_key_constraint(:ticket_type_id)
  end
end
