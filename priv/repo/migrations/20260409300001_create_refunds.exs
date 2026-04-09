defmodule TicketService.Repo.Migrations.CreateRefunds do
  use Ecto.Migration

  def change do
    create table(:refunds, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :order_id, references(:orders, type: :binary_id, on_delete: :restrict), null: false
      add :order_item_id, references(:order_items, type: :binary_id, on_delete: :restrict)
      add :type, :string, null: false
      add :amount, :decimal, null: false
      add :reason, :string
      add :stripe_refund_id, :string
      add :status, :string, null: false, default: "pending"
      add :initiated_by, :string
      add :fee_refund_amount, :decimal
      add :metadata, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:refunds, [:order_id])
    create index(:refunds, [:order_item_id])
    create index(:refunds, [:stripe_refund_id])
  end
end
