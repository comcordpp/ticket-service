defmodule TicketService.Repo.Migrations.CreateEvents do
  use Ecto.Migration

  def change do
    create table(:events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :title, :string, null: false
      add :description, :text
      add :category, :string
      add :status, :string, null: false, default: "draft"
      add :starts_at, :utc_datetime, null: false
      add :ends_at, :utc_datetime
      add :venue_id, references(:venues, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:events, [:status])
    create index(:events, [:venue_id])
    create index(:events, [:starts_at])
    create index(:events, [:category])
  end
end
