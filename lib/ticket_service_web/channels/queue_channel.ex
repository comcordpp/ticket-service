defmodule TicketServiceWeb.QueueChannel do
  @moduledoc """
  RT-2: Queue Position Updates channel.

  Pushes queue position every 5 seconds. Sends redirect notification
  within 3 seconds when client reaches the front of the queue.
  """
  use Phoenix.Channel

  alias TicketService.Queue.FairQueue

  @position_update_interval_ms 5_000

  @impl true
  def join("queue:" <> event_id, _params, socket) do
    session_id = socket.assigns.session_id
    socket = assign(socket, :event_id, event_id)

    # Start periodic position updates
    send(self(), :send_position_update)

    {:ok, socket}
  end

  @impl true
  def handle_info(:send_position_update, socket) do
    event_id = socket.assigns.event_id
    session_id = socket.assigns.session_id

    case FairQueue.check_status(event_id, session_id) do
      {:pass, %{expires_at: expires_at}} ->
        push(socket, "queue:ready", %{
          status: "pass",
          expires_at: DateTime.to_iso8601(expires_at),
          message: "Your turn! Proceed to ticket selection."
        })

      {:wait, %{position: pos, total: total}} ->
        push(socket, "queue:position", %{
          status: "waiting",
          position: pos,
          total: total,
          estimated_wait_seconds: estimate_wait(pos)
        })

        schedule_update()

      {:not_in_queue, _} ->
        push(socket, "queue:status", %{status: "not_in_queue"})
    end

    {:noreply, socket}
  end

  @impl true
  def handle_in("request_access", _params, socket) do
    event_id = socket.assigns.event_id
    session_id = socket.assigns.session_id

    case FairQueue.request_access(event_id, session_id) do
      :pass ->
        push(socket, "queue:ready", %{
          status: "pass",
          message: "No queue — proceed directly."
        })

      {:queued, position} ->
        push(socket, "queue:position", %{
          status: "queued",
          position: position,
          estimated_wait_seconds: estimate_wait(position)
        })

        schedule_update()

      {:wait, position} ->
        push(socket, "queue:position", %{
          status: "waiting",
          position: position,
          estimated_wait_seconds: estimate_wait(position)
        })
    end

    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    # Clean up queue pass on disconnect
    event_id = socket.assigns[:event_id]
    session_id = socket.assigns[:session_id]

    if event_id && session_id do
      FairQueue.release_pass(event_id, session_id)
    end

    :ok
  end

  defp schedule_update do
    Process.send_after(self(), :send_position_update, @position_update_interval_ms)
  end

  defp estimate_wait(position) do
    # Rough estimate: ~2 seconds per position in queue
    position * 2
  end
end
