defmodule TicketService.Tickets.Ticket do
  @moduledoc """
  E-Ticket schema — represents a scannable digital ticket.

  Each ticket has a unique token, HMAC-signed QR payload, and QR code data.
  One ticket is generated per ticket in the order (e.g., 3 GA tickets = 3 Ticket records).

  Status transitions: sold -> delivered (email sent) -> scanned (at venue)
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(sold delivered scanned cancelled)

  schema "tickets" do
    field :token, :string
    field :qr_data, :string
    field :qr_hash, :string
    field :qr_payload, :string
    field :holder_email, :string
    field :holder_name, :string
    field :status, :string, default: "sold"
    field :scanned_at, :utc_datetime
    field :emailed_at, :utc_datetime
    field :delivered_at, :utc_datetime

    belongs_to :order, TicketService.Orders.Order
    belongs_to :order_item, TicketService.Orders.OrderItem
    belongs_to :event, TicketService.Events.Event

    timestamps(type: :utc_datetime)
  end

  def changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [
      :token, :qr_data, :qr_hash, :qr_payload,
      :holder_email, :holder_name, :status,
      :scanned_at, :emailed_at, :delivered_at,
      :order_id, :order_item_id, :event_id
    ])
    |> validate_required([:token, :qr_data, :qr_hash, :order_id, :order_item_id, :event_id])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:token)
    |> unique_constraint(:qr_hash)
    |> foreign_key_constraint(:order_id)
    |> foreign_key_constraint(:order_item_id)
    |> foreign_key_constraint(:event_id)
  end

  def statuses, do: @statuses
end
