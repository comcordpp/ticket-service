defmodule TicketService.Repo.Migrations.AddStripeFieldsAndTickets do
  use Ecto.Migration

  def change do
    # Add Stripe payment fields to orders
    alter table(:orders) do
      add :stripe_payment_intent_id, :string
      add :stripe_refund_id, :string
      add :payment_method, :string, default: "card"
      add :refund_amount, :decimal, precision: 12, scale: 2
      add :refund_reason, :string
      add :refunded_at, :utc_datetime
    end

    create index(:orders, [:stripe_payment_intent_id], unique: true)

    # Create e-tickets table
    create table(:tickets, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :token, :string, null: false
      add :qr_data, :text, null: false
      add :holder_email, :string
      add :holder_name, :string
      add :status, :string, null: false, default: "active"
      add :scanned_at, :utc_datetime
      add :emailed_at, :utc_datetime
      add :order_id, references(:orders, type: :binary_id, on_delete: :delete_all), null: false
      add :order_item_id, references(:order_items, type: :binary_id, on_delete: :delete_all), null: false
      add :event_id, references(:events, type: :binary_id, on_delete: :nothing), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tickets, [:token])
    create index(:tickets, [:order_id])
    create index(:tickets, [:event_id])
    create index(:tickets, [:status])
  end
end
