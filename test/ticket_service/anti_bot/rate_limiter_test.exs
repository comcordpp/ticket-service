defmodule TicketService.AntiBot.RateLimiterTest do
  use ExUnit.Case, async: false

  alias TicketService.AntiBot.RateLimiter

  setup do
    start_supervised!(RateLimiter)

    Application.put_env(:ticket_service, RateLimiter,
      ip_limit: 5,
      ip_window_ms: 1_000,
      session_limit: 3,
      session_window_ms: 1_000,
      endpoints: %{
        "cart_add" => %{ip_limit: 3, session_limit: 2, window_ms: 1_000},
        "checkout" => %{ip_limit: 2, session_limit: 1, window_ms: 1_000}
      },
      event_overrides: %{
        "high-demand-event" => %{ip_limit: 2, session_limit: 1, window_ms: 1_000}
      },
      allowlist: ["10.0.0.1"],
      blocklist: ["192.168.1.100"]
    )

    on_exit(fn -> Application.delete_env(:ticket_service, RateLimiter) end)
    :ok
  end

  describe "IP rate limiting" do
    test "allows requests under the limit" do
      key = "ip-#{System.unique_integer([:positive])}"
      assert {:ok, %{limit: 5, remaining: 4}} = RateLimiter.check(key)
      assert {:ok, %{limit: 5, remaining: 3}} = RateLimiter.check(key)
      assert {:ok, %{limit: 5, remaining: 2}} = RateLimiter.check(key)
    end

    test "blocks requests over the limit" do
      key = "ip-rate-test-#{System.unique_integer([:positive])}"

      for _ <- 1..5 do
        {:ok, _} = RateLimiter.check(key)
      end

      assert {:error, :rate_limited, info} = RateLimiter.check(key)
      assert info.remaining == 0
      assert is_integer(info.retry_after_ms) and info.retry_after_ms > 0
    end

    test "returns rate limit info with limit, remaining, and reset_ms" do
      key = "ip-info-#{System.unique_integer([:positive])}"
      assert {:ok, info} = RateLimiter.check(key)
      assert info.limit == 5
      assert info.remaining == 4
      assert is_integer(info.reset_ms)
    end
  end

  describe "session rate limiting" do
    test "enforces session-specific limits" do
      key = {:session, "sess-#{System.unique_integer([:positive])}"}

      for _ <- 1..3 do
        {:ok, _} = RateLimiter.check(key)
      end

      assert {:error, :rate_limited, info} = RateLimiter.check(key)
      assert info.limit == 3
      assert info.remaining == 0
    end

    test "session and IP limits are independent" do
      ip = "ip-indep-#{System.unique_integer([:positive])}"
      session = {:session, "sess-indep-#{System.unique_integer([:positive])}"}

      # Exhaust session limit (3)
      for _ <- 1..3, do: RateLimiter.check(session)
      assert {:error, :rate_limited, _} = RateLimiter.check(session)

      # IP limit still has room
      assert {:ok, _} = RateLimiter.check(ip)
    end
  end

  describe "endpoint-specific limits" do
    test "uses cart_add endpoint limits" do
      key = "ip-cart-#{System.unique_integer([:positive])}"

      for _ <- 1..3 do
        {:ok, _} = RateLimiter.check(key, "cart_add")
      end

      assert {:error, :rate_limited, _} = RateLimiter.check(key, "cart_add")
      # Default endpoint still has room
      assert {:ok, _} = RateLimiter.check(key, "default")
    end

    test "uses checkout endpoint limits" do
      key = "ip-checkout-#{System.unique_integer([:positive])}"

      for _ <- 1..2 do
        {:ok, _} = RateLimiter.check(key, "checkout")
      end

      assert {:error, :rate_limited, _} = RateLimiter.check(key, "checkout")
    end
  end

  describe "per-event overrides" do
    test "applies stricter limits for high-demand events" do
      key = "ip-event-#{System.unique_integer([:positive])}"

      for _ <- 1..2 do
        {:ok, _} = RateLimiter.check(key, "default", event_id: "high-demand-event")
      end

      assert {:error, :rate_limited, _} =
               RateLimiter.check(key, "default", event_id: "high-demand-event")
    end

    test "falls back to endpoint config when no event override exists" do
      key = "ip-no-event-#{System.unique_integer([:positive])}"

      # Should use default limits (5) not event override
      for _ <- 1..5 do
        {:ok, _} = RateLimiter.check(key, "default", event_id: "regular-event")
      end

      assert {:error, :rate_limited, _} =
               RateLimiter.check(key, "default", event_id: "regular-event")
    end
  end

  describe "allowlist/blocklist" do
    test "recognizes allowlisted IPs" do
      assert RateLimiter.allowlisted?("10.0.0.1")
      refute RateLimiter.allowlisted?("10.0.0.2")
    end

    test "recognizes blocklisted IPs" do
      assert RateLimiter.blocklisted?("192.168.1.100")
      refute RateLimiter.blocklisted?("192.168.1.1")
    end
  end

  describe "current_count" do
    test "tracks current count accurately" do
      key = "ip-count-#{System.unique_integer([:positive])}"
      assert RateLimiter.current_count(key) == 0

      RateLimiter.check(key)
      assert RateLimiter.current_count(key) == 1

      RateLimiter.check(key)
      assert RateLimiter.current_count(key) == 2
    end
  end

  describe "reset" do
    test "clears a key's counter" do
      key = "ip-reset-#{System.unique_integer([:positive])}"
      for _ <- 1..3, do: RateLimiter.check(key)
      RateLimiter.reset(key)
      assert RateLimiter.current_count(key) == 0
    end
  end

  describe "sliding window" do
    test "requests expire after window" do
      key = "ip-window-#{System.unique_integer([:positive])}"

      # Use a very short window for testing
      Application.put_env(:ticket_service, RateLimiter,
        ip_limit: 2,
        ip_window_ms: 50,
        session_limit: 1,
        session_window_ms: 50,
        endpoints: %{},
        event_overrides: %{},
        allowlist: [],
        blocklist: []
      )

      for _ <- 1..2, do: RateLimiter.check(key)
      assert {:error, :rate_limited, _} = RateLimiter.check(key)

      # Wait for window to expire
      Process.sleep(60)
      assert {:ok, _} = RateLimiter.check(key)
    end
  end
end
