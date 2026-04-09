defmodule TicketServiceWeb.Plugs.BotGuardTest do
  use TicketServiceWeb.ConnCase

  alias TicketService.AntiBot.Detector

  setup do
    start_supervised!(Detector)
    :ok
  end

  test "passes normal requests through", %{conn: conn} do
    conn =
      conn
      |> put_req_header("user-agent", "Mozilla/5.0")
      |> put_req_header("x-browser-fingerprint", "fp123")
      |> put_req_header("x-js-executed", "true")
      |> put_req_header("x-session-id", "test-session")
      |> TicketServiceWeb.Plugs.BotGuard.call([])

    refute conn.halted
    assert conn.assigns[:bot_score] == 0
    assert conn.assigns[:session_id] == "test-session"
  end

  test "challenges bot user-agents with 403", %{conn: conn} do
    conn =
      conn
      |> put_req_header("user-agent", "Scraperbot/1.0")
      |> put_req_header("x-session-id", "bot-session")
      |> TicketServiceWeb.Plugs.BotGuard.call([])

    assert conn.halted
    assert conn.status == 403
    body = Jason.decode!(conn.resp_body)
    assert body["error"] in ["captcha_required", "blocked"]
  end

  test "extracts session ID from header", %{conn: conn} do
    conn =
      conn
      |> put_req_header("user-agent", "Mozilla/5.0")
      |> put_req_header("x-browser-fingerprint", "fp123")
      |> put_req_header("x-js-executed", "true")
      |> put_req_header("x-session-id", "my-session-123")
      |> TicketServiceWeb.Plugs.BotGuard.call([])

    assert conn.assigns[:session_id] == "my-session-123"
  end

  test "falls back to IP when no session header", %{conn: conn} do
    conn =
      conn
      |> put_req_header("user-agent", "Mozilla/5.0")
      |> put_req_header("x-browser-fingerprint", "fp123")
      |> put_req_header("x-js-executed", "true")
      |> TicketServiceWeb.Plugs.BotGuard.call([])

    refute conn.halted
    assert is_binary(conn.assigns[:session_id])
  end
end
