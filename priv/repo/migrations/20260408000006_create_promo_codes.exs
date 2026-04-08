defmodule TicketService.Repo.Migrations.CreatePromoCodes do
  use Ecto.Migration

  def change do
    create table(:promo_codes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :code, :string, null: false
      add :discount_type, :string, null: false
      add :discount_value, :decimal, null: false
      add :max_uses, :integer
      add :used_count, :integer, null: false, default: 0
      add :valid_from, :utc_datetime
      add :valid_until, :utc_datetime
      add :active, :boolean, null: false, default: true
      add :event_id, references(:events, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:promo_codes, [:event_id])
    create unique_index(:promo_codes, [:event_id, :code])
  end
end
