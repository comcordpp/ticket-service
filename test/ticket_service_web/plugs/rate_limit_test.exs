defmodule TicketServiceWeb.Plugs.RateLimitTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias TicketService.AntiBot.RateLimiter
  alias TicketServiceWeb.Plugs.RateLimit

  setup do
    start_supervised!(RateLimiter)

    Application.put_env(:ticket_service, RateLimiter,
      ip_limit: 3,
      ip_window_ms: 1_000,
      session_limit: 2,
      session_window_ms: 1_000,
      endpoints: %{
        "checkout" => %{ip_limit: 2, session_limit: 1, window_ms: 1_000}
      },
      event_overrides: %{},
      allowlist: ["10.0.0.1"],
      blocklist: ["192.168.1.100"]
    )

    on_exit(fn -> Application.delete_env(:ticket_service, RateLimiter) end)
    :ok
  end

  defp call_plug(conn, opts \\ []) do
    opts = RateLimit.init(opts)
    RateLimit.call(conn, opts)
  end

  defp build_conn_with_ip(ip, path \\ "/api/test") do
    conn(:get, path)
    |> put_req_header("x-forwarded-for", ip)
    |> Map.put(:path_params, %{})
    |> Map.put(:params, %{})
  end

  describe "rate limit headers" do
    test "adds X-RateLimit-* headers on successful requests" do
      conn =
        build_conn_with_ip("1.2.3.#{System.unique_integer([:positive])}")
        |> call_plug()

      assert get_resp_header(conn, "x-ratelimit-limit") != []
      assert get_resp_header(conn, "x-ratelimit-remaining") != []
      assert get_resp_header(conn, "x-ratelimit-reset") != []
      refute conn.halted
    end

    test "remaining count decreases with each request" do
      ip = "1.2.3.#{System.unique_integer([:positive])}"

      conn1 = build_conn_with_ip(ip) |> call_plug()
      [remaining1] = get_resp_header(conn1, "x-ratelimit-remaining")

      conn2 = build_conn_with_ip(ip) |> call_plug()
      [remaining2] = get_resp_header(conn2, "x-ratelimit-remaining")

      assert String.to_integer(remaining1) > String.to_integer(remaining2)
    end
  end

  describe "IP rate limiting in plug" do
    test "returns 429 when IP limit exceeded" do
      ip = "5.6.7.#{System.unique_integer([:positive])}"

      for _ <- 1..3 do
        conn = build_conn_with_ip(ip) |> call_plug()
        refute conn.halted
      end

      conn = build_conn_with_ip(ip) |> call_plug()
      assert conn.status == 429
      assert conn.halted

      assert [retry_after] = get_resp_header(conn, "retry-after")
      assert String.to_integer(retry_after) > 0

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "Too Many Requests"
      assert body["message"] =~ "Rate limit exceeded"
      assert is_integer(body["retry_after"])
      assert is_binary(body["retry_at"])
    end
  end

  describe "session rate limiting in plug" do
    test "enforces session limits from path_params" do
      ip = "9.8.7.#{System.unique_integer([:positive])}"
      session_id = "sess-#{System.unique_integer([:positive])}"

      build_request = fn ->
        conn(:get, "/api/carts/#{session_id}")
        |> put_req_header("x-forwarded-for", ip)
        |> Map.put(:path_params, %{"session_id" => session_id})
        |> Map.put(:params, %{"session_id" => session_id})
      end

      # Session limit is 2
      conn1 = build_request.() |> call_plug()
      refute conn1.halted

      conn2 = build_request.() |> call_plug()
      refute conn2.halted

      conn3 = build_request.() |> call_plug()
      assert conn3.status == 429
      assert conn3.halted
    end
  end

  describe "X-Forwarded-For handling" do
    test "uses first IP from X-Forwarded-For" do
      ip = "203.0.113.#{System.unique_integer([:positive])}"

      conn =
        conn(:get, "/api/test")
        |> put_req_header("x-forwarded-for", "#{ip}, 10.0.0.1, 10.0.0.2")
        |> Map.put(:path_params, %{})
        |> Map.put(:params, %{})
        |> call_plug()

      refute conn.halted
      assert get_resp_header(conn, "x-ratelimit-remaining") != []
    end

    test "falls back to remote_ip when no X-Forwarded-For" do
      conn =
        conn(:get, "/api/test")
        |> Map.put(:path_params, %{})
        |> Map.put(:params, %{})
        |> call_plug()

      refute conn.halted
    end
  end

  describe "allowlist" do
    test "bypasses rate limiting for allowlisted IPs" do
      for _ <- 1..10 do
        conn = build_conn_with_ip("10.0.0.1") |> call_plug()
        refute conn.halted
        assert get_resp_header(conn, "x-ratelimit-limit") == []
      end
    end
  end

  describe "blocklist" do
    test "returns 403 for blocklisted IPs" do
      conn = build_conn_with_ip("192.168.1.100") |> call_plug()
      assert conn.status == 403
      assert conn.halted

      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "Forbidden"
    end
  end

  describe "endpoint-specific limits" do
    test "uses checkout endpoint limits" do
      ip = "11.12.13.#{System.unique_integer([:positive])}"

      # Checkout limit is 2
      for _ <- 1..2 do
        conn = build_conn_with_ip(ip) |> call_plug(endpoint: "checkout")
        refute conn.halted
      end

      conn = build_conn_with_ip(ip) |> call_plug(endpoint: "checkout")
      assert conn.status == 429
    end
  end
end
