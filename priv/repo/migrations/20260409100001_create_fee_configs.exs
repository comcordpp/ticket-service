defmodule TicketService.Repo.Migrations.CreateFeeConfigs do
  use Ecto.Migration

  def change do
    create table(:fee_configs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :event_id, references(:events, type: :binary_id, on_delete: :delete_all), null: false
      add :service_fee_pct, :decimal, null: false, default: 10.0
      add :platform_fee_flat, :integer, null: false, default: 150
      add :platform_fee_pct, :decimal, null: false, default: 0.0
      add :tax_rate, :decimal, null: false, default: 0.0

      timestamps(type: :utc_datetime)
    end

    create unique_index(:fee_configs, [:event_id])
  end
end
