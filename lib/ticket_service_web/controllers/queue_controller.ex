defmodule TicketServiceWeb.QueueController do
  use TicketServiceWeb, :controller

  alias TicketService.Queue.FairQueue

  @doc "POST /api/events/:event_id/queue/join — join the event queue."
  def join(conn, %{"event_id" => event_id}) do
    session_id = get_session_id(conn)

    case FairQueue.join(event_id, session_id) do
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

      {:error, :queue_full} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "Queue is full. Please try again later."})
    end
  end

  @doc "GET /api/events/:event_id/queue/position/:session_id — check queue position."
  def position(conn, %{"event_id" => event_id, "session_id" => session_id}) do
    case FairQueue.check_position(event_id, session_id) do
      {:pass, %{expires_at: expires_at}} ->
        json(conn, %{data: %{status: "pass", expires_at: expires_at}})

      {:wait, %{position: pos, total: total}} ->
        json(conn, %{data: %{status: "waiting", position: pos, total: total, estimated_wait_seconds: pos * 2}})

      {:not_in_queue, _} ->
        json(conn, %{data: %{status: "not_in_queue"}})
    end
  end

  @doc "GET /api/admin/events/:event_id/queue/stats — admin queue statistics."
  def stats(conn, %{"event_id" => event_id}) do
    case FairQueue.stats(event_id) do
      {:ok, stats} ->
        json(conn, %{data: stats})

      {:error, :queue_not_found} ->
        json(conn, %{data: %{
          event_id: event_id,
          active: false,
          queue_depth: 0,
          active_passes: 0,
          drain_rate: 0,
          current_request_rate: 0.0,
          avg_wait_seconds: 0.0,
          total_admitted: 0
        }})
    end
  end

  # Backward-compatible endpoints (kept for existing callers)
  def request_access(conn, %{"event_id" => event_id, "session_id" => session_id}) do
    case FairQueue.join(event_id, session_id) do
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

      {:error, :queue_full} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "Queue is full. Please try again later."})
    end
  end

  def status(conn, %{"event_id" => event_id, "session_id" => session_id}) do
    case FairQueue.check_position(event_id, session_id) do
      {:pass, %{expires_at: expires_at}} ->
        json(conn, %{data: %{status: "pass", expires_at: expires_at}})

      {:wait, %{position: pos, total: total}} ->
        json(conn, %{data: %{status: "waiting", position: pos, total: total}})

      {:not_in_queue, _} ->
        json(conn, %{data: %{status: "not_in_queue"}})
    end
  end

  defp get_session_id(conn) do
    case get_req_header(conn, "x-session-id") do
      [session_id | _] -> session_id
      [] ->
        case conn.params do
          %{"session_id" => sid} -> sid
          _ -> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
        end
    end
  end
end
