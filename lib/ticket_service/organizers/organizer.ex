defmodule TicketService.Organizers.Organizer do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "organizers" do
    field :name, :string
    field :email, :string
    field :stripe_account_id, :string
    field :stripe_onboarding_complete, :boolean, default: false
    field :stripe_charges_enabled, :boolean, default: false
    field :stripe_payouts_enabled, :boolean, default: false

    has_many :events, TicketService.Events.Event

    timestamps(type: :utc_datetime)
  end

  @cast_fields [:name, :email, :stripe_account_id, :stripe_onboarding_complete,
                 :stripe_charges_enabled, :stripe_payouts_enabled]

  def changeset(organizer, attrs) do
    organizer
    |> cast(attrs, @cast_fields)
    |> validate_required([:name, :email])
    |> validate_format(:email, ~r/@/)
    |> unique_constraint(:email)
    |> unique_constraint(:stripe_account_id)
  end
end
