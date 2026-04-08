defmodule TicketService.SeatingTest do
  use TicketService.DataCase, async: true

  alias TicketService.Seating
  alias TicketService.Venues

  setup do
    {:ok, venue} = Venues.create_venue(%{name: "Test Arena", capacity: 5000})
    {:ok, venue: venue}
  end

  describe "create_section/1" do
    test "creates a general admission section", %{venue: venue} do
      attrs = %{name: "Floor GA", type: "general_admission", capacity: 1000, venue_id: venue.id}
      assert {:ok, section} = Seating.create_section(attrs)
      assert section.name == "Floor GA"
      assert section.type == "general_admission"
      assert section.seats == [] # GA has no individual seats
    end

    test "creates a reserved section with auto-generated seats", %{venue: venue} do
      attrs = %{
        name: "Section A",
        type: "reserved",
        capacity: 50,
        row_count: 5,
        seats_per_row: 10,
        venue_id: venue.id
      }
      assert {:ok, section} = Seating.create_section(attrs)
      assert section.type == "reserved"
      assert length(section.seats) == 50
      # Check row labels are generated correctly
      row_labels = section.seats |> Enum.map(& &1.row_label) |> Enum.uniq() |> Enum.sort()
      assert row_labels == ["A", "B", "C", "D", "E"]
    end

    test "creates a VIP section with seats", %{venue: venue} do
      attrs = %{
        name: "VIP Box",
        type: "vip",
        capacity: 20,
        row_count: 2,
        seats_per_row: 10,
        venue_id: venue.id
      }
      assert {:ok, section} = Seating.create_section(attrs)
      assert section.type == "vip"
      assert length(section.seats) == 20
    end

    test "requires row_count and seats_per_row for reserved sections", %{venue: venue} do
      attrs = %{name: "Section B", type: "reserved", capacity: 50, venue_id: venue.id}
      assert {:error, changeset} = Seating.create_section(attrs)
      assert %{row_count: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates section type", %{venue: venue} do
      attrs = %{name: "Bad", type: "invalid", capacity: 100, venue_id: venue.id}
      assert {:error, changeset} = Seating.create_section(attrs)
      assert %{type: [_]} = errors_on(changeset)
    end
  end

  describe "list_sections/1" do
    test "lists sections for a venue", %{venue: venue} do
      {:ok, _} = Seating.create_section(%{name: "GA", type: "general_admission", capacity: 500, venue_id: venue.id})
      {:ok, _} = Seating.create_section(%{name: "VIP", type: "vip", capacity: 20, row_count: 2, seats_per_row: 10, venue_id: venue.id})
      sections = Seating.list_sections(venue.id)
      assert length(sections) == 2
    end
  end

  describe "list_seats/1" do
    test "lists seats for a section ordered by row and number", %{venue: venue} do
      {:ok, section} = Seating.create_section(%{
        name: "Section A", type: "reserved", capacity: 15,
        row_count: 3, seats_per_row: 5, venue_id: venue.id
      })
      seats = Seating.list_seats(section.id)
      assert length(seats) == 15
      first = hd(seats)
      assert first.row_label == "A"
      assert first.seat_number == 1
    end
  end
end
