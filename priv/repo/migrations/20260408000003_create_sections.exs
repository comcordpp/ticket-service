defmodule TicketService.Repo.Migrations.CreateSections do
  use Ecto.Migration

  def change do
    create table(:sections, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :type, :string, null: false
      add :capacity, :integer, null: false
      add :row_count, :integer
      add :seats_per_row, :integer
      add :venue_id, references(:venues, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:sections, [:venue_id])
  end
end
