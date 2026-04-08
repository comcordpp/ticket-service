defmodule TicketService.Repo.Migrations.CreateVenues do
  use Ecto.Migration

  def change do
    create table(:venues, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :address, :text
      add :capacity, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:venues, [:name])
  end
end
