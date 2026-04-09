defmodule TicketServiceWeb.QueueController do
  use TicketServiceWeb, :controller

  alias TicketService.Queue.FairQueue

  @doc "Request access to the queue for an event."
  def request_access(conn, %{"event_id" => event_id, "session_id" => session_id}) do
    case FairQueue.request_access(event_id, session_id) do
      :pass ->
        json(conn, %{data: %{status: "pass", message: "Proceed to checkout"}})

      {:queued, position} ->
        conn
        |> put_status(:accepted)
        |> json(%{data: %{status: "queued", position: position}})

      {:wait, position} ->
        conn
        |> put_status(:accepted)
        |> json(%{data: %{status: "waiting", position: position}})
    end
  end

  @doc "Check queue position."
  def status(conn, %{"event_id" => event_id, "session_id" => session_id}) do
    case FairQueue.check_status(event_id, session_id) do
      {:pass, %{expires_at: expires_at}} ->
        json(conn, %{data: %{status: "pass", expires_at: expires_at}})

      {:wait, %{position: pos, total: total}} ->
        json(conn, %{data: %{status: "waiting", position: pos, total: total}})

      {:not_in_queue, _} ->
        json(conn, %{data: %{status: "not_in_queue"}})
    end
  end
end
