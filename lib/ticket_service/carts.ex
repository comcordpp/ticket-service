defmodule TicketService.Carts do
  @moduledoc """
  The Carts context — manages per-session shopping carts backed by GenServer processes.

  Each session gets a dedicated CartServer process under a DynamicSupervisor.
  Carts auto-expire after a configurable TTL (default 10 min), releasing held inventory.
  """
  import Ecto.Query
  alias TicketService.Repo
  alias TicketService.Carts.CartServer
  alias TicketService.Tickets.TicketType
  alias TicketService.Seating.Seat

  @default_ttl_ms :timer.minutes(10)

  @doc "Start or retrieve an existing cart for the given session."
  def get_or_create_cart(session_id, opts \\ []) do
    ttl = Keyword.get(opts, :ttl_ms, @default_ttl_ms)

    case lookup(session_id) do
      {:ok, _pid} ->
        CartServer.get_cart(session_id)

      :error ->
        case DynamicSupervisor.start_child(
               TicketService.CartSupervisor,
               {CartServer, {session_id, [ttl_ms: ttl]}}
             ) do
          {:ok, _pid} -> CartServer.get_cart(session_id)
          {:error, {:already_started, _pid}} -> CartServer.get_cart(session_id)
          error -> error
        end
    end
  end

  @doc "Add a ticket to the cart, holding inventory via optimistic locking."
  def add_item(session_id, ticket_type_id, quantity \\ 1, opts \\ []) do
    seat_ids = Keyword.get(opts, :seat_ids, [])

    with {:ok, _pid} <- ensure_cart(session_id),
         :ok <- hold_inventory(ticket_type_id, quantity, seat_ids) do
      CartServer.add_item(session_id, ticket_type_id, quantity, seat_ids: seat_ids)
    end
  end

  @doc "Remove a ticket from the cart, releasing held inventory."
  def remove_item(session_id, ticket_type_id) do
    with {:ok, _pid} <- ensure_cart(session_id),
         {:ok, cart_before} <- CartServer.get_cart(session_id) do
      item = Enum.find(cart_before.items, &(&1.ticket_type_id == ticket_type_id))

      case item do
        nil ->
          {:error, :item_not_found}

        %{quantity: qty, seat_ids: seat_ids} ->
          release_inventory(ticket_type_id, qty, seat_ids)
          CartServer.remove_item(session_id, ticket_type_id)
      end
    end
  end

  @doc "Update item quantity in the cart, adjusting inventory holds."
  def update_quantity(session_id, ticket_type_id, new_quantity) do
    with {:ok, _pid} <- ensure_cart(session_id),
         {:ok, cart_before} <- CartServer.get_cart(session_id) do
      item = Enum.find(cart_before.items, &(&1.ticket_type_id == ticket_type_id))

      case item do
        nil ->
          {:error, :item_not_found}

        %{quantity: old_qty} when new_quantity > old_qty ->
          diff = new_quantity - old_qty

          case hold_inventory(ticket_type_id, diff, []) do
            :ok -> CartServer.update_quantity(session_id, ticket_type_id, new_quantity)
            error -> error
          end

        %{quantity: old_qty} when new_quantity < old_qty ->
          diff = old_qty - new_quantity
          release_inventory(ticket_type_id, diff, [])
          CartServer.update_quantity(session_id, ticket_type_id, new_quantity)

        _ ->
          CartServer.get_cart(session_id)
      end
    end
  end

  @doc "Get current cart contents."
  def get_cart(session_id) do
    case lookup(session_id) do
      {:ok, _pid} -> CartServer.get_cart(session_id)
      :error -> {:error, :cart_not_found}
    end
  end

  @doc "Clear all items from the cart, releasing all held inventory."
  def clear_cart(session_id) do
    with {:ok, _pid} <- ensure_cart(session_id),
         {:ok, cart} <- CartServer.get_cart(session_id) do
      Enum.each(cart.items, fn item ->
        release_inventory(item.ticket_type_id, item.quantity, item.seat_ids)
      end)

      CartServer.clear(session_id)
    end
  end

  @doc "Check if a cart process exists for this session."
  def cart_exists?(session_id) do
    match?({:ok, _}, lookup(session_id))
  end

  # --- Inventory Management ---

  @doc "Public callback for CartServer.terminate/2 — releases held inventory on cart expiry."
  def release_inventory_on_expiry(ticket_type_id, quantity, seat_ids) do
    release_inventory(ticket_type_id, quantity, seat_ids)
  end

  defp hold_inventory(ticket_type_id, quantity, seat_ids) do
    Repo.transaction(fn ->
      # Optimistic lock: increment sold_count only if enough remain
      result =
        from(tt in TicketType,
          where: tt.id == ^ticket_type_id,
          where: tt.quantity - tt.sold_count >= ^quantity
        )
        |> Repo.update_all(inc: [sold_count: quantity])

      case result do
        {1, _} ->
          hold_seats(seat_ids)

        {0, _} ->
          Repo.rollback(:insufficient_inventory)
      end
    end)
    |> case do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp release_inventory(ticket_type_id, quantity, seat_ids) do
    from(tt in TicketType,
      where: tt.id == ^ticket_type_id,
      where: tt.sold_count >= ^quantity
    )
    |> Repo.update_all(inc: [sold_count: -quantity])

    release_seats(seat_ids)
  end

  defp hold_seats([]), do: :ok

  defp hold_seats(seat_ids) do
    {count, _} =
      from(s in Seat,
        where: s.id in ^seat_ids,
        where: s.status == "available"
      )
      |> Repo.update_all(set: [status: "held", updated_at: DateTime.utc_now() |> DateTime.truncate(:second)])

    if count == length(seat_ids) do
      :ok
    else
      # Rollback any partial holds
      from(s in Seat, where: s.id in ^seat_ids, where: s.status == "held")
      |> Repo.update_all(set: [status: "available", updated_at: DateTime.utc_now() |> DateTime.truncate(:second)])

      Repo.rollback(:seats_unavailable)
    end
  end

  defp release_seats([]), do: :ok

  defp release_seats(seat_ids) do
    from(s in Seat,
      where: s.id in ^seat_ids,
      where: s.status == "held"
    )
    |> Repo.update_all(set: [status: "available", updated_at: DateTime.utc_now() |> DateTime.truncate(:second)])
  end

  # --- Process Lookup ---

  defp lookup(session_id) do
    case Registry.lookup(TicketService.CartRegistry, session_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp ensure_cart(session_id) do
    case lookup(session_id) do
      {:ok, pid} -> {:ok, pid}
      :error -> {:error, :cart_not_found}
    end
  end
end
