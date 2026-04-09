defmodule TicketServiceWeb.Plugs.BotGuard do
  @moduledoc """
  Plug that runs bot detection analysis on requests.

  Extracts session_id and browser signals, checks risk score,
  and blocks or challenges suspicious traffic.

  Usage:

      plug TicketServiceWeb.Plugs.BotGuard
  """
  import Plug.Conn

  alias TicketService.AntiBot.Detector

  def init(opts), do: opts

  def call(conn, _opts) do
    session_id = get_session_id(conn)

    signals = %{
      user_agent: get_req_header(conn, "user-agent") |> List.first(),
      fingerprint: get_req_header(conn, "x-browser-fingerprint") |> List.first()
    }

    case Detector.analyze(session_id, signals) do
      {:ok, :pass} ->
        assign(conn, :bot_score, 0)

      {:ok, :captcha_required, score} ->
        conn
        |> put_status(403)
        |> Phoenix.Controller.json(%{
          error: "captcha_required",
          captcha_challenge_url: "/api/captcha/challenge",
          score: score
        })
        |> halt()

      {:ok, :blocked, score} ->
        conn
        |> put_status(403)
        |> Phoenix.Controller.json(%{
          error: "blocked",
          message: "Request blocked due to suspicious activity",
          score: score
        })
        |> halt()
    end
  end

  defp get_session_id(conn) do
    # Try session header, then query param, then IP
    case get_req_header(conn, "x-session-id") do
      [sid | _] -> sid
      [] ->
        case conn.params["session_id"] do
          nil -> conn.remote_ip |> :inet.ntoa() |> to_string()
          sid -> sid
        end
    end
  end
end
