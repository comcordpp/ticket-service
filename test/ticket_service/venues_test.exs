defmodule TicketService.VenuesTest do
  use TicketService.DataCase, async: true

  alias TicketService.Venues
  alias TicketService.Venues.Venue

  @valid_attrs %{name: "Madison Square Garden", address: "4 Pennsylvania Plaza, NYC", capacity: 20_000}

  describe "create_venue/1" do
    test "creates a venue with valid attrs" do
      assert {:ok, %Venue{} = venue} = Venues.create_venue(@valid_attrs)
      assert venue.name == "Madison Square Garden"
      assert venue.capacity == 20_000
    end

    test "requires name" do
      assert {:error, changeset} = Venues.create_venue(%{capacity: 100})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires capacity" do
      assert {:error, changeset} = Venues.create_venue(%{name: "Test"})
      assert %{capacity: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates capacity > 0" do
      assert {:error, changeset} = Venues.create_venue(%{name: "Test", capacity: 0})
      assert %{capacity: [_]} = errors_on(changeset)
    end
  end

  describe "update_venue/2" do
    test "updates venue fields" do
      {:ok, venue} = Venues.create_venue(@valid_attrs)
      assert {:ok, updated} = Venues.update_venue(venue, %{name: "New Name"})
      assert updated.name == "New Name"
    end
  end

  describe "list_venues/0" do
    test "lists all venues ordered by name" do
      {:ok, _} = Venues.create_venue(%{name: "Zebra Arena", capacity: 100})
      {:ok, _} = Venues.create_venue(%{name: "Alpha Hall", capacity: 200})
      venues = Venues.list_venues()
      assert length(venues) == 2
      assert hd(venues).name == "Alpha Hall"
    end
  end
end
