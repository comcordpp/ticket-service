defmodule TicketService.Repo.Migrations.CreateTicketTypes do
  use Ecto.Migration

  def change do
    create table(:ticket_types, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :price, :decimal, null: false
      add :quantity, :integer, null: false
      add :sold_count, :integer, null: false, default: 0
      add :sale_starts_at, :utc_datetime
      add :sale_ends_at, :utc_datetime
      add :event_id, references(:events, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:ticket_types, [:event_id])
  end
end
