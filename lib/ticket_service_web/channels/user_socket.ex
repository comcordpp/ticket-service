defmodule TicketServiceWeb.UserSocket do
  use Phoenix.Socket

  channel "seat_map:*", TicketServiceWeb.SeatMapChannel
  channel "queue:*", TicketServiceWeb.QueueChannel
  channel "cart:*", TicketServiceWeb.CartChannel
  channel "dashboard:*", TicketServiceWeb.DashboardChannel

  @impl true
  def connect(params, socket, _connect_info) do
    session_id = Map.get(params, "session_id", generate_id())
    {:ok, assign(socket, :session_id, session_id)}
  end

  @impl true
  def id(socket), do: "user:#{socket.assigns.session_id}"

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end
end
