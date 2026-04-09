defmodule TicketService.Repo.Migrations.CreateOccupancySnapshots do
  use Ecto.Migration

  def change do
    create table(:occupancy_snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :venue_id, references(:venues, type: :binary_id, on_delete: :delete_all), null: false
      add :section_id, references(:sections, type: :binary_id, on_delete: :delete_all), null: false
      add :count, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:occupancy_snapshots, [:venue_id])
    create index(:occupancy_snapshots, [:venue_id, :section_id])
  end
end
