defmodule TicketService.TicketsTest do
  use TicketService.DataCase, async: true

  alias TicketService.Tickets
  alias TicketService.Tickets.{TicketType, PromoCode}
  alias TicketService.Events

  setup do
    {:ok, event} = Events.create_event(%{title: "Test Event", starts_at: ~U[2026-07-15 18:00:00Z]})
    {:ok, event: event}
  end

  describe "ticket types" do
    test "creates a ticket type", %{event: event} do
      attrs = %{name: "General Admission", price: 25.00, quantity: 500, event_id: event.id}
      assert {:ok, %TicketType{} = tt} = Tickets.create_ticket_type(attrs)
      assert tt.name == "General Admission"
      assert Decimal.equal?(tt.price, Decimal.new("25.0"))
      assert tt.sold_count == 0
    end

    test "validates required fields", %{event: event} do
      assert {:error, changeset} = Tickets.create_ticket_type(%{event_id: event.id})
      errors = errors_on(changeset)
      assert errors[:name]
      assert errors[:price]
      assert errors[:quantity]
    end

    test "validates price >= 0", %{event: event} do
      attrs = %{name: "Free", price: -1, quantity: 10, event_id: event.id}
      assert {:error, changeset} = Tickets.create_ticket_type(attrs)
      assert %{price: [_]} = errors_on(changeset)
    end

    test "validates sale window ordering", %{event: event} do
      attrs = %{
        name: "Early Bird", price: 15.00, quantity: 50, event_id: event.id,
        sale_starts_at: ~U[2026-07-15 18:00:00Z],
        sale_ends_at: ~U[2026-07-15 10:00:00Z]
      }
      assert {:error, changeset} = Tickets.create_ticket_type(attrs)
      assert %{sale_ends_at: ["must be after sale start time"]} = errors_on(changeset)
    end

    test "lists ticket types for an event", %{event: event} do
      {:ok, _} = Tickets.create_ticket_type(%{name: "GA", price: 25, quantity: 100, event_id: event.id})
      {:ok, _} = Tickets.create_ticket_type(%{name: "VIP", price: 100, quantity: 20, event_id: event.id})
      assert length(Tickets.list_ticket_types(event.id)) == 2
    end
  end

  describe "update_ticket_type/2 with sales (field locking)" do
    setup %{event: event} do
      {:ok, tt} = Tickets.create_ticket_type(%{
        name: "General", price: Decimal.new("25.00"), quantity: 100, event_id: event.id
      })

      # Publish and create a confirmed order to trigger has_sales?
      {:ok, _published} = Events.publish_event(event)
      {:ok, _order} =
        Repo.insert(%TicketService.Orders.Order{
          session_id: "test-session",
          event_id: event.id,
          status: "confirmed",
          subtotal: Decimal.new("25.00"),
          platform_fee: Decimal.new("1.13"),
          processing_fee: Decimal.new("1.06"),
          total: Decimal.new("27.19")
        })

      %{ticket_type: tt}
    end

    test "allows updating name with sales", %{ticket_type: tt} do
      assert {:ok, updated} = Tickets.update_ticket_type(tt, %{name: "New Name"})
      assert updated.name == "New Name"
    end

    test "rejects changing price after sales", %{ticket_type: tt} do
      assert {:error, changeset} = Tickets.update_ticket_type(tt, %{price: Decimal.new("50.00")})
      assert %{price: ["cannot be changed after tickets have been sold"]} = errors_on(changeset)
    end

    test "rejects changing quantity after sales", %{ticket_type: tt} do
      assert {:error, changeset} = Tickets.update_ticket_type(tt, %{quantity: 200})
      assert %{quantity: ["cannot be changed after tickets have been sold"]} = errors_on(changeset)
    end
  end

  describe "promo codes" do
    test "creates a percentage promo code", %{event: event} do
      attrs = %{code: "SUMMER20", discount_type: "percentage", discount_value: 20, event_id: event.id}
      assert {:ok, %PromoCode{} = pc} = Tickets.create_promo_code(attrs)
      assert pc.code == "SUMMER20"
      assert pc.discount_type == "percentage"
      assert pc.active == true
    end

    test "creates a fixed promo code", %{event: event} do
      attrs = %{code: "SAVE5", discount_type: "fixed", discount_value: 5.00, event_id: event.id}
      assert {:ok, pc} = Tickets.create_promo_code(attrs)
      assert pc.discount_type == "fixed"
    end

    test "validates percentage <= 100", %{event: event} do
      attrs = %{code: "TOOMUCH", discount_type: "percentage", discount_value: 150, event_id: event.id}
      assert {:error, changeset} = Tickets.create_promo_code(attrs)
      assert %{discount_value: [_]} = errors_on(changeset)
    end

    test "validates discount_value > 0", %{event: event} do
      attrs = %{code: "ZERO", discount_type: "fixed", discount_value: 0, event_id: event.id}
      assert {:error, changeset} = Tickets.create_promo_code(attrs)
      assert %{discount_value: [_]} = errors_on(changeset)
    end

    test "enforces unique code per event", %{event: event} do
      attrs = %{code: "DUPE", discount_type: "fixed", discount_value: 5, event_id: event.id}
      {:ok, _} = Tickets.create_promo_code(attrs)
      assert {:error, changeset} = Tickets.create_promo_code(attrs)
      assert %{event_id: [_]} = errors_on(changeset)
    end

    test "validates a valid promo code", %{event: event} do
      {:ok, _} = Tickets.create_promo_code(%{code: "VALID", discount_type: "fixed", discount_value: 5, event_id: event.id})
      assert {:ok, promo} = Tickets.validate_promo_code(event.id, "VALID")
      assert promo.code == "VALID"
    end

    test "returns error for unknown code", %{event: event} do
      assert {:error, :not_found} = Tickets.validate_promo_code(event.id, "NOPE")
    end

    test "returns error for inactive code", %{event: event} do
      {:ok, pc} = Tickets.create_promo_code(%{code: "OFF", discount_type: "fixed", discount_value: 5, event_id: event.id})
      Tickets.update_promo_code(pc, %{active: false})
      assert {:error, :inactive} = Tickets.validate_promo_code(event.id, "OFF")
    end
  end
end
