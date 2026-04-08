defmodule TicketService.Repo.Migrations.CreateOrders do
  use Ecto.Migration

  def change do
    create table(:orders, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :session_id, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :subtotal, :decimal, precision: 12, scale: 2, null: false
      add :platform_fee, :decimal, precision: 12, scale: 2, null: false
      add :processing_fee, :decimal, precision: 12, scale: 2, null: false
      add :discount_amount, :decimal, precision: 12, scale: 2, null: false, default: 0
      add :total, :decimal, precision: 12, scale: 2, null: false
      add :checkout_token, :string
      add :checkout_expires_at, :utc_datetime
      add :event_id, references(:events, type: :binary_id, on_delete: :restrict), null: false
      add :promo_code_id, references(:promo_codes, type: :binary_id, on_delete: :nothing)

      timestamps(type: :utc_datetime)
    end

    create index(:orders, [:session_id])
    create index(:orders, [:event_id])
    create index(:orders, [:status])
    create unique_index(:orders, [:checkout_token])

    create table(:order_items, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :quantity, :integer, null: false
      add :unit_price, :decimal, precision: 12, scale: 2, null: false
      add :order_id, references(:orders, type: :binary_id, on_delete: :delete_all), null: false
      add :ticket_type_id, references(:ticket_types, type: :binary_id, on_delete: :restrict), null: false
      add :seat_ids, {:array, :binary_id}, default: []

      timestamps(type: :utc_datetime)
    end

    create index(:order_items, [:order_id])
    create index(:order_items, [:ticket_type_id])
  end
end
