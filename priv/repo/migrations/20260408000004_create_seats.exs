defmodule TicketService.Repo.Migrations.CreateSeats do
  use Ecto.Migration

  def change do
    create table(:seats, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :row_label, :string, null: false
      add :seat_number, :integer, null: false
      add :status, :string, null: false, default: "available"
      add :section_id, references(:sections, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:seats, [:section_id])
    create unique_index(:seats, [:section_id, :row_label, :seat_number])
  end
end
