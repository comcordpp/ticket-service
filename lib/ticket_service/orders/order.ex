defmodule TicketService.Orders.Order do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending confirmed cancelled refunded partially_refunded)

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

    # Stripe payment fields
    field :stripe_payment_intent_id, :string
    field :stripe_refund_id, :string
    field :payment_method, :string, default: "card"
    field :refund_amount, :decimal
    field :refund_reason, :string
    field :refunded_at, :utc_datetime

    belongs_to :event, TicketService.Events.Event
    belongs_to :promo_code, TicketService.Tickets.PromoCode
    has_many :order_items, TicketService.Orders.OrderItem
    has_many :tickets, TicketService.Tickets.Ticket
    has_many :refunds, TicketService.Payments.Refund

    timestamps(type: :utc_datetime)
  end

  @cast_fields [
    :session_id, :status, :subtotal, :platform_fee, :processing_fee,
    :discount_amount, :total, :checkout_token, :checkout_expires_at,
    :event_id, :promo_code_id, :stripe_payment_intent_id, :stripe_refund_id,
    :payment_method, :refund_amount, :refund_reason, :refunded_at
  ]

  def changeset(order, attrs) do
    order
    |> cast(attrs, @cast_fields)
    |> validate_required([:session_id, :status, :subtotal, :platform_fee, :processing_fee, :total, :event_id])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:checkout_token)
    |> unique_constraint(:stripe_payment_intent_id)
    |> foreign_key_constraint(:event_id)
    |> foreign_key_constraint(:promo_code_id)
  end

  def statuses, do: @statuses
end
