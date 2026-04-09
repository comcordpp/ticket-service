defmodule TicketServiceWeb.Plugs.BotGuard do
  @moduledoc """
  Plug that runs bot detection analysis on requests.

  Extracts session_id and browser signals (user-agent, accept-language,
  screen resolution, fingerprint, JS execution marker), checks risk score,
  and blocks or challenges suspicious traffic.

  Usage:

      plug TicketServiceWeb.Plugs.BotGuard
  """
  import Plug.Conn

  alias TicketService.AntiBot.Detector

  def init(opts), do: opts

  def call(conn, _opts) do
    session_id = get_session_id(conn)
    ip = client_ip(conn)

    signals = %{
      user_agent: get_req_header(conn, "user-agent") |> List.first(),
      fingerprint: get_req_header(conn, "x-browser-fingerprint") |> List.first(),
      accept_language: get_req_header(conn, "accept-language") |> List.first(),
      screen_resolution: get_req_header(conn, "x-screen-resolution") |> List.first(),
      js_executed: get_req_header(conn, "x-js-executed") |> List.first() == "true",
      ip: ip,
      event_id: conn.path_params["event_id"] || conn.params["event_id"]
    }

    case Detector.analyze(session_id, signals) do
      {:ok, :pass} ->
        conn
        |> assign(:bot_score, 0)
        |> assign(:session_id, session_id)

      {:ok, :captcha_required, score} ->
        conn
        |> put_status(403)
        |> Phoenix.Controller.json(%{
          error: "captcha_required",
          captcha_challenge_url: "/api/captcha/challenge",
          site_key: TicketService.AntiBot.CaptchaProvider.site_key(),
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
    case get_req_header(conn, "x-session-id") do
      [sid | _] -> sid
      [] ->
        case conn.params["session_id"] do
          nil -> client_ip(conn)
          sid -> sid
        end
    end
  end

  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded |> String.split(",") |> List.first() |> String.trim()

      [] ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
