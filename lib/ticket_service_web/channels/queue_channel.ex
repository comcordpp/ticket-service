defmodule TicketServiceWeb.QueueChannel do
  @moduledoc """
  RT-2: Queue Position Updates channel.

  Pushes queue position every 5 seconds. Sends redirect notification
  within 3 seconds when client reaches the front of the queue.
  Also listens for PubSub pass-granted events for immediate notification.
  """
  use Phoenix.Channel

  alias TicketService.Queue.FairQueue

  @position_update_interval_ms 5_000

  @impl true
  def join("queue:" <> event_id, _params, socket) do
    session_id = socket.assigns.session_id
    socket = assign(socket, :event_id, event_id)

    # Subscribe to PubSub for immediate pass notifications
    Phoenix.PubSub.subscribe(TicketService.PubSub, "queue:#{event_id}")

    # Start periodic position updates
    send(self(), :send_position_update)

    {:ok, socket}
  end

  @impl true
  def handle_info({:queue_pass_granted, session_id}, socket) do
    if socket.assigns.session_id == session_id do
      event_id = socket.assigns.event_id

      case FairQueue.check_position(event_id, session_id) do
        {:pass, %{expires_at: expires_at}} ->
          push(socket, "queue:ready", %{
            status: "pass",
            expires_at: DateTime.to_iso8601(expires_at),
            message: "Your turn! Proceed to ticket selection."
          })

        _ ->
          :ok
      end
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:send_position_update, socket) do
    event_id = socket.assigns.event_id
    session_id = socket.assigns.session_id

    case FairQueue.check_position(event_id, session_id) do
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
  def handle_in("join", _params, socket) do
    event_id = socket.assigns.event_id
    session_id = socket.assigns.session_id

    case FairQueue.join(event_id, session_id) do
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

      {:error, :queue_full} ->
        push(socket, "queue:error", %{
          status: "full",
          message: "Queue is full. Please try again later."
        })
    end

    {:noreply, socket}
  end

  # Keep backward compat for "request_access" event name
  @impl true
  def handle_in("request_access", params, socket), do: handle_in("join", params, socket)

  @impl true
  def terminate(_reason, socket) do
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
    # Rough estimate based on default drain rate of 50/sec
    max(div(position, 50), 1)
  end
end
