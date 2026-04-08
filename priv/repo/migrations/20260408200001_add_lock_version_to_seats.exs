defmodule TicketService.Repo.Migrations.AddLockVersionToSeats do
  use Ecto.Migration

  def change do
    alter table(:seats) do
      add :lock_version, :integer, default: 1, null: false
    end
  end
end
