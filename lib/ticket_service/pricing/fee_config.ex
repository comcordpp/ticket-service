defmodule TicketService.Pricing.FeeConfig do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "fee_configs" do
    field :service_fee_pct, :decimal
    field :platform_fee_flat, :integer
    field :platform_fee_pct, :decimal
    field :tax_rate, :decimal

    belongs_to :event, TicketService.Events.Event

    timestamps(type: :utc_datetime)
  end

  def changeset(fee_config, attrs) do
    fee_config
    |> cast(attrs, [:event_id, :service_fee_pct, :platform_fee_flat, :platform_fee_pct, :tax_rate])
    |> validate_required([:event_id])
    |> validate_number(:service_fee_pct, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:platform_fee_flat, greater_than_or_equal_to: 0)
    |> validate_number(:platform_fee_pct, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:tax_rate, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> unique_constraint(:event_id)
    |> foreign_key_constraint(:event_id)
  end
end
