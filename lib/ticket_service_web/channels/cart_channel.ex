defmodule TicketServiceWeb.CartChannel do
  @moduledoc """
  RT-3: Cart Timer channel.

  Syncs cart countdown with the CartServer GenServer TTL.
  Pushes remaining time every second. Warns at 2 minutes.
  Sends clear notification at expiry.
  """
  use Phoenix.Channel

  alias TicketService.Carts

  @tick_interval_ms 1_000
  @warning_threshold_seconds 120

  @impl true
  def join("cart:" <> session_id, _params, socket) do
    socket = assign(socket, :cart_session_id, session_id)

    # Start timer ticks
    send(self(), :tick)

    {:ok, socket}
  end

  @impl true
  def handle_info(:tick, socket) do
    session_id = socket.assigns.cart_session_id

    case Carts.get_cart(session_id) do
      {:ok, cart} ->
        remaining = cart_remaining_seconds(cart)

        cond do
          remaining <= 0 ->
            push(socket, "cart:expired", %{
              message: "Your cart has expired. Items have been released."
            })

          remaining <= @warning_threshold_seconds ->
            push(socket, "cart:warning", %{
              remaining_seconds: remaining,
              message: "Your cart expires in #{remaining} seconds!"
            })

            Process.send_after(self(), :tick, @tick_interval_ms)

          true ->
            push(socket, "cart:timer", %{
              remaining_seconds: remaining
            })

            Process.send_after(self(), :tick, @tick_interval_ms)
        end

        {:noreply, socket}

      {:error, :cart_not_found} ->
        push(socket, "cart:empty", %{message: "No active cart"})
        {:noreply, socket}
    end
  end

  @impl true
  def handle_in("refresh", _params, socket) do
    send(self(), :tick)
    {:noreply, socket}
  end

  defp cart_remaining_seconds(cart) do
    ttl_ms = :timer.minutes(10)
    elapsed_ms = DateTime.diff(DateTime.utc_now(), cart.last_activity_at, :millisecond)
    remaining_ms = max(ttl_ms - elapsed_ms, 0)
    div(remaining_ms, 1000)
  end
end
