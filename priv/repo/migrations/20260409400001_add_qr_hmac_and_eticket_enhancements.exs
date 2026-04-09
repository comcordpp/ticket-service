defmodule TicketService.Repo.Migrations.AddQrHmacAndEticketEnhancements do
  use Ecto.Migration

  def change do
    alter table(:tickets) do
      add :qr_hash, :string
      add :qr_payload, :text
      add :delivered_at, :utc_datetime
    end

    create index(:tickets, [:qr_hash], unique: true)
  end
end
