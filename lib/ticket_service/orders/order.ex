defmodule TicketService.Orders.Order do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending confirmed cancelled refunded)

  schema "orders" do
    field :session_id, :string
    field :status, :string, default: "pending"
    field :subtotal, :decimal
    field :platform_fee, :decimal
    field :processing_fee, :decimal
    field :discount_amount, :decimal, default: Decimal.new(0)
    field :total, :decimal
    field :checkout_token, :string
    field :checkout_expires_at, :utc_datetime

    belongs_to :event, TicketService.Events.Event
    belongs_to :promo_code, TicketService.Tickets.PromoCode
    has_many :order_items, TicketService.Orders.OrderItem

    timestamps(type: :utc_datetime)
  end

  def changeset(order, attrs) do
    order
    |> cast(attrs, [
      :session_id, :status, :subtotal, :platform_fee, :processing_fee,
      :discount_amount, :total, :checkout_token, :checkout_expires_at,
      :event_id, :promo_code_id
    ])
    |> validate_required([:session_id, :status, :subtotal, :platform_fee, :processing_fee, :total, :event_id])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:checkout_token)
    |> foreign_key_constraint(:event_id)
    |> foreign_key_constraint(:promo_code_id)
  end

  def statuses, do: @statuses
end
