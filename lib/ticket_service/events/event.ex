defmodule TicketService.Events.Event do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(draft published cancelled)

  schema "events" do
    field :title, :string
    field :description, :string
    field :category, :string
    field :status, :string, default: "draft"
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime

    belongs_to :venue, TicketService.Venues.Venue
    has_many :ticket_types, TicketService.Tickets.TicketType
    has_many :sections, through: [:venue, :sections]

    timestamps(type: :utc_datetime)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:title, :description, :category, :status, :starts_at, :ends_at, :venue_id])
    |> validate_required([:title, :starts_at])
    |> validate_inclusion(:status, @statuses)
    |> validate_dates()
    |> foreign_key_constraint(:venue_id)
  end

  def publish_changeset(event) do
    event
    |> change(status: "published")
    |> validate_publishable()
  end

  defp validate_dates(changeset) do
    case {get_field(changeset, :starts_at), get_field(changeset, :ends_at)} do
      {starts, ends} when not is_nil(starts) and not is_nil(ends) ->
        if DateTime.compare(ends, starts) == :gt do
          changeset
        else
          add_error(changeset, :ends_at, "must be after start time")
        end

      _ ->
        changeset
    end
  end

  defp validate_publishable(changeset) do
    event = changeset.data

    cond do
      event.status != "draft" ->
        add_error(changeset, :status, "only draft events can be published")

      true ->
        changeset
    end
  end

  def statuses, do: @statuses
end
