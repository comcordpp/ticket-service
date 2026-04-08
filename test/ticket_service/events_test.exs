defmodule TicketService.EventsTest do
  use TicketService.DataCase, async: true

  alias TicketService.Events
  alias TicketService.Events.Event
  alias TicketService.Venues
  alias TicketService.Tickets
  alias TicketService.Orders
  alias TicketService.Orders.Order

  @valid_attrs %{
    title: "Summer Music Festival",
    description: "A great outdoor music event",
    category: "music",
    starts_at: ~U[2026-07-15 18:00:00Z],
    ends_at: ~U[2026-07-15 23:00:00Z]
  }

  describe "create_event/1" do
    test "creates an event with valid attrs" do
      assert {:ok, %Event{} = event} = Events.create_event(@valid_attrs)
      assert event.title == "Summer Music Festival"
      assert event.status == "draft"
      assert event.category == "music"
    end

    test "requires title" do
      assert {:error, changeset} = Events.create_event(%{starts_at: ~U[2026-07-15 18:00:00Z]})
      assert %{title: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires starts_at" do
      assert {:error, changeset} = Events.create_event(%{title: "Test"})
      assert %{starts_at: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates ends_at is after starts_at" do
      attrs = Map.put(@valid_attrs, :ends_at, ~U[2026-07-15 10:00:00Z])
      assert {:error, changeset} = Events.create_event(attrs)
      assert %{ends_at: ["must be after start time"]} = errors_on(changeset)
    end

    test "validates status inclusion" do
      attrs = Map.put(@valid_attrs, :status, "invalid")
      assert {:error, changeset} = Events.create_event(attrs)
      assert %{status: [_]} = errors_on(changeset)
    end

    test "associates venue" do
      {:ok, venue} = Venues.create_venue(%{name: "Arena", capacity: 5000})
      attrs = Map.put(@valid_attrs, :venue_id, venue.id)
      assert {:ok, event} = Events.create_event(attrs)
      assert event.venue_id == venue.id
    end
  end

  describe "update_event/2" do
    test "updates event fields" do
      {:ok, event} = Events.create_event(@valid_attrs)
      assert {:ok, updated} = Events.update_event(event, %{title: "Updated Title"})
      assert updated.title == "Updated Title"
    end
  end

  describe "delete_event/1" do
    test "deletes the event" do
      {:ok, event} = Events.create_event(@valid_attrs)
      assert {:ok, _} = Events.delete_event(event)
      assert Events.get_event(event.id) == nil
    end
  end

  describe "publish_event/1" do
    test "publishes a draft event with ticket types" do
      {:ok, event} = Events.create_event(@valid_attrs)
      {:ok, _tt} = Tickets.create_ticket_type(%{
        name: "General", price: 25.00, quantity: 100, event_id: event.id
      })
      assert {:ok, published} = Events.publish_event(event)
      assert published.status == "published"
    end

    test "rejects publishing without ticket types" do
      {:ok, event} = Events.create_event(@valid_attrs)
      assert {:error, :no_ticket_types} = Events.publish_event(event)
    end

    test "rejects publishing a non-draft event" do
      {:ok, event} = Events.create_event(@valid_attrs)
      {:ok, _tt} = Tickets.create_ticket_type(%{
        name: "General", price: 25.00, quantity: 100, event_id: event.id
      })
      {:ok, published} = Events.publish_event(event)
      assert {:error, changeset} = Events.publish_event(published)
      assert %{status: ["only draft events can be published"]} = errors_on(changeset)
    end
  end

  describe "cancel_event/1" do
    test "cancels an event" do
      {:ok, event} = Events.create_event(@valid_attrs)
      assert {:ok, cancelled} = Events.cancel_event(event)
      assert cancelled.status == "cancelled"
    end

    test "rejects cancelling an already cancelled event" do
      {:ok, event} = Events.create_event(@valid_attrs)
      {:ok, cancelled} = Events.cancel_event(event)
      assert {:error, :already_cancelled} = Events.cancel_event(cancelled)
    end

    test "cancels event with confirmed orders and marks them cancelled" do
      {:ok, venue} = Venues.create_venue(%{name: "Arena", capacity: 5000})
      {:ok, event} = Events.create_event(Map.put(@valid_attrs, :venue_id, venue.id))
      {:ok, tt} = Tickets.create_ticket_type(%{
        name: "General", price: Decimal.new("25.00"), quantity: 100, event_id: event.id
      })
      {:ok, _published} = Events.publish_event(event)

      # Create a confirmed order
      {:ok, order} =
        Repo.insert(%Order{
          session_id: "test-session",
          event_id: event.id,
          status: "confirmed",
          subtotal: Decimal.new("25.00"),
          platform_fee: Decimal.new("1.13"),
          processing_fee: Decimal.new("1.06"),
          total: Decimal.new("27.19")
        })

      {:ok, cancelled} = Events.cancel_event(%{event | status: "published"})
      assert cancelled.status == "cancelled"

      # Order should be cancelled
      updated_order = Repo.get(Order, order.id)
      assert updated_order.status == "cancelled"
    end
  end

  describe "update_event/2 with cancelled event" do
    test "rejects editing a cancelled event" do
      {:ok, event} = Events.create_event(@valid_attrs)
      {:ok, cancelled} = Events.cancel_event(event)
      assert {:error, :event_cancelled} = Events.update_event(cancelled, %{title: "New Title"})
    end
  end

  describe "update_event/2 with sales (field locking)" do
    setup do
      {:ok, venue} = Venues.create_venue(%{name: "Arena", capacity: 5000})
      {:ok, event} = Events.create_event(Map.merge(@valid_attrs, %{venue_id: venue.id}))
      {:ok, tt} = Tickets.create_ticket_type(%{
        name: "General", price: Decimal.new("25.00"), quantity: 100, event_id: event.id
      })
      {:ok, published} = Events.publish_event(event)

      # Create a confirmed order to trigger has_sales?
      {:ok, _order} =
        Repo.insert(%Order{
          session_id: "test-session",
          event_id: event.id,
          status: "confirmed",
          subtotal: Decimal.new("25.00"),
          platform_fee: Decimal.new("1.13"),
          processing_fee: Decimal.new("1.06"),
          total: Decimal.new("27.19")
        })

      %{event: %{published | status: "published"}, venue: venue, ticket_type: tt}
    end

    test "allows editing title and description", %{event: event} do
      assert {:ok, updated} = Events.update_event(event, %{title: "New Title", description: "New desc"})
      assert updated.title == "New Title"
      assert updated.description == "New desc"
    end

    test "rejects changing venue_id after sales", %{event: event} do
      {:ok, venue2} = Venues.create_venue(%{name: "Arena 2", capacity: 3000})
      assert {:error, changeset} = Events.update_event(event, %{venue_id: venue2.id})
      assert %{venue_id: ["cannot be changed after tickets have been sold"]} = errors_on(changeset)
    end

    test "rejects changing starts_at after sales", %{event: event} do
      assert {:error, changeset} = Events.update_event(event, %{starts_at: ~U[2026-08-01 18:00:00Z]})
      assert %{starts_at: ["cannot be changed after tickets have been sold"]} = errors_on(changeset)
    end

    test "rejects changing category after sales", %{event: event} do
      assert {:error, changeset} = Events.update_event(event, %{category: "sports"})
      assert %{category: ["cannot be changed after tickets have been sold"]} = errors_on(changeset)
    end
  end

  describe "list_events/1" do
    test "lists all events" do
      {:ok, _e1} = Events.create_event(@valid_attrs)
      {:ok, _e2} = Events.create_event(Map.put(@valid_attrs, :title, "Event 2"))
      assert length(Events.list_events()) == 2
    end

    test "filters by status" do
      {:ok, _e1} = Events.create_event(@valid_attrs)
      events = Events.list_events(%{status: "draft"})
      assert length(events) == 1
    end
  end

  describe "list_published_events/0" do
    test "returns only published events" do
      {:ok, event} = Events.create_event(@valid_attrs)
      {:ok, _tt} = Tickets.create_ticket_type(%{
        name: "General", price: 25.00, quantity: 100, event_id: event.id
      })
      {:ok, _published} = Events.publish_event(event)
      {:ok, _draft} = Events.create_event(Map.put(@valid_attrs, :title, "Draft Event"))

      published = Events.list_published_events()
      assert length(published) == 1
      assert hd(published).status == "published"
    end
  end
end
