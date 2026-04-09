defmodule TicketService.Tickets.Ticket do
  @moduledoc """
  E-Ticket schema — represents a scannable digital ticket.

  Each ticket has a unique token and QR code data. One ticket is generated
  per ticket in the order (e.g., 3 GA tickets = 3 Ticket records).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(active used cancelled)

  schema "tickets" do
    field :token, :string
    field :qr_data, :string
    field :holder_email, :string
    field :holder_name, :string
    field :status, :string, default: "active"
    field :scanned_at, :utc_datetime
    field :emailed_at, :utc_datetime

    belongs_to :order, TicketService.Orders.Order
    belongs_to :order_item, TicketService.Orders.OrderItem
    belongs_to :event, TicketService.Events.Event

    timestamps(type: :utc_datetime)
  end

  def changeset(ticket, attrs) do
    ticket
    |> cast(attrs, [
      :token, :qr_data, :holder_email, :holder_name, :status,
      :scanned_at, :emailed_at, :order_id, :order_item_id, :event_id
    ])
    |> validate_required([:token, :qr_data, :order_id, :order_item_id, :event_id])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:token)
    |> foreign_key_constraint(:order_id)
    |> foreign_key_constraint(:order_item_id)
    |> foreign_key_constraint(:event_id)
  end

  def statuses, do: @statuses
end
