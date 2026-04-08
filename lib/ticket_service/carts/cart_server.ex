defmodule TicketService.Carts.CartServer do
  @moduledoc """
  GenServer process representing a per-session shopping cart.
  Auto-expires after a configurable TTL of inactivity (default 10 minutes).
  """
  use GenServer

  alias TicketService.Carts.CartServer

  @default_ttl_ms :timer.minutes(10)

  defstruct session_id: nil,
            items: %{},
            created_at: nil,
            last_activity_at: nil

  # --- Client API ---

  def start_link({session_id, opts}) do
    ttl = Keyword.get(opts, :ttl_ms, @default_ttl_ms)
    name = via(session_id)
    GenServer.start_link(__MODULE__, {session_id, ttl}, name: name)
  end

  def via(session_id) do
    {:via, Registry, {TicketService.CartRegistry, session_id}}
  end

  def add_item(session_id, ticket_type_id, quantity \\ 1, opts \\ []) do
    GenServer.call(via(session_id), {:add_item, ticket_type_id, quantity, opts})
  end

  def remove_item(session_id, ticket_type_id) do
    GenServer.call(via(session_id), {:remove_item, ticket_type_id})
  end

  def update_quantity(session_id, ticket_type_id, quantity) do
    GenServer.call(via(session_id), {:update_quantity, ticket_type_id, quantity})
  end

  def get_cart(session_id) do
    GenServer.call(via(session_id), :get_cart)
  end

  def clear(session_id) do
    GenServer.call(via(session_id), :clear)
  end

  # --- Server Callbacks ---

  @impl true
  def init({session_id, ttl}) do
    now = DateTime.utc_now()

    state = %{
      cart: %CartServer{
        session_id: session_id,
        items: %{},
        created_at: now,
        last_activity_at: now
      },
      ttl: ttl
    }

    {:ok, state, ttl}
  end

  @impl true
  def handle_call({:add_item, ticket_type_id, quantity, opts}, _from, state) when quantity > 0 do
    seat_ids = Keyword.get(opts, :seat_ids, [])
    cart = state.cart
    items = cart.items

    new_items =
      Map.update(items, ticket_type_id, %{quantity: quantity, seat_ids: seat_ids}, fn existing ->
        %{existing | quantity: existing.quantity + quantity, seat_ids: existing.seat_ids ++ seat_ids}
      end)

    new_cart = %{cart | items: new_items, last_activity_at: DateTime.utc_now()}
    new_state = %{state | cart: new_cart}
    {:reply, {:ok, format_cart(new_cart)}, new_state, state.ttl}
  end

  def handle_call({:add_item, _ticket_type_id, _quantity, _opts}, _from, state) do
    {:reply, {:error, :invalid_quantity}, state, state.ttl}
  end

  @impl true
  def handle_call({:remove_item, ticket_type_id}, _from, state) do
    cart = state.cart

    case Map.fetch(cart.items, ticket_type_id) do
      {:ok, _} ->
        new_items = Map.delete(cart.items, ticket_type_id)
        new_cart = %{cart | items: new_items, last_activity_at: DateTime.utc_now()}
        new_state = %{state | cart: new_cart}
        {:reply, {:ok, format_cart(new_cart)}, new_state, state.ttl}

      :error ->
        {:reply, {:error, :item_not_found}, state, state.ttl}
    end
  end

  @impl true
  def handle_call({:update_quantity, ticket_type_id, quantity}, _from, state) when quantity > 0 do
    cart = state.cart

    case Map.fetch(cart.items, ticket_type_id) do
      {:ok, existing} ->
        new_items = Map.put(cart.items, ticket_type_id, %{existing | quantity: quantity})
        new_cart = %{cart | items: new_items, last_activity_at: DateTime.utc_now()}
        new_state = %{state | cart: new_cart}
        {:reply, {:ok, format_cart(new_cart)}, new_state, state.ttl}

      :error ->
        {:reply, {:error, :item_not_found}, state, state.ttl}
    end
  end

  def handle_call({:update_quantity, _ticket_type_id, _quantity}, _from, state) do
    {:reply, {:error, :invalid_quantity}, state, state.ttl}
  end

  @impl true
  def handle_call(:get_cart, _from, state) do
    {:reply, {:ok, format_cart(state.cart)}, state, state.ttl}
  end

  @impl true
  def handle_call(:clear, _from, state) do
    new_cart = %{state.cart | items: %{}, last_activity_at: DateTime.utc_now()}
    new_state = %{state | cart: new_cart}
    {:reply, {:ok, format_cart(new_cart)}, new_state, state.ttl}
  end

  @impl true
  def handle_info(:timeout, state) do
    {:stop, {:shutdown, :ttl_expired}, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Release all held inventory when cart process dies (TTL expiry, crash, clear)
    Enum.each(state.cart.items, fn {ticket_type_id, item} ->
      TicketService.Carts.release_inventory_on_expiry(ticket_type_id, item.quantity, item.seat_ids)
    end)

    :ok
  end

  defp format_cart(%CartServer{} = cart) do
    %{
      session_id: cart.session_id,
      items: Enum.map(cart.items, fn {ticket_type_id, item} ->
        %{
          ticket_type_id: ticket_type_id,
          quantity: item.quantity,
          seat_ids: item.seat_ids
        }
      end),
      item_count: map_size(cart.items),
      total_tickets: Enum.reduce(cart.items, 0, fn {_, item}, acc -> acc + item.quantity end),
      created_at: cart.created_at,
      last_activity_at: cart.last_activity_at
    }
  end
end
