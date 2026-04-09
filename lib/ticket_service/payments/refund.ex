defmodule TicketService.Payments.Refund do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @types ~w(full partial)
  @statuses ~w(pending succeeded failed)

  schema "refunds" do
    field :type, :string
    field :amount, :decimal
    field :reason, :string
    field :stripe_refund_id, :string
    field :status, :string, default: "pending"
    field :initiated_by, :string
    field :fee_refund_amount, :decimal
    field :metadata, :map, default: %{}

    belongs_to :order, TicketService.Orders.Order
    belongs_to :order_item, TicketService.Orders.OrderItem

    timestamps(type: :utc_datetime)
  end

  @cast_fields [
    :type, :amount, :reason, :stripe_refund_id, :status, :initiated_by,
    :fee_refund_amount, :metadata, :order_id, :order_item_id
  ]

  def changeset(refund, attrs) do
    refund
    |> cast(attrs, @cast_fields)
    |> validate_required([:type, :amount, :order_id, :status])
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:amount, greater_than: 0)
    |> foreign_key_constraint(:order_id)
    |> foreign_key_constraint(:order_item_id)
  end

  def types, do: @types
  def statuses, do: @statuses
end
