defmodule TicketService.Repo.Migrations.CreateOrganizersAndLinkEvents do
  use Ecto.Migration

  def change do
    create table(:organizers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :email, :string, null: false
      add :stripe_account_id, :string
      add :stripe_onboarding_complete, :boolean, default: false, null: false
      add :stripe_charges_enabled, :boolean, default: false, null: false
      add :stripe_payouts_enabled, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:organizers, [:email])
    create unique_index(:organizers, [:stripe_account_id])

    alter table(:events) do
      add :organizer_id, references(:organizers, type: :binary_id, on_delete: :nothing)
    end

    create index(:events, [:organizer_id])
  end
end
