defmodule TicketService.AntiBot.RateLimiterTest do
  use ExUnit.Case, async: false

  alias TicketService.AntiBot.RateLimiter

  setup do
    # Start the rate limiter for tests
    start_supervised!(RateLimiter)

    Application.put_env(:ticket_service, RateLimiter,
      default_limit: 5,
      default_window_ms: 1_000,
      endpoints: %{
        "cart_add" => %{limit: 3, window_ms: 1_000}
      }
    )

    on_exit(fn -> Application.delete_env(:ticket_service, RateLimiter) end)
    :ok
  end

  test "allows requests under the limit" do
    assert :ok = RateLimiter.check("ip-1")
    assert :ok = RateLimiter.check("ip-1")
    assert :ok = RateLimiter.check("ip-1")
  end

  test "blocks requests over the limit" do
    key = "ip-rate-test-#{System.unique_integer([:positive])}"

    for _ <- 1..5, do: RateLimiter.check(key)

    assert {:error, :rate_limited, retry_after} = RateLimiter.check(key)
    assert is_integer(retry_after) and retry_after > 0
  end

  test "uses endpoint-specific limits" do
    key = "ip-endpoint-#{System.unique_integer([:positive])}"

    for _ <- 1..3, do: RateLimiter.check(key, "cart_add")

    assert {:error, :rate_limited, _} = RateLimiter.check(key, "cart_add")
    # Default endpoint still has room
    assert :ok = RateLimiter.check(key, "default")
  end

  test "tracks current count" do
    key = "ip-count-#{System.unique_integer([:positive])}"
    assert RateLimiter.current_count(key) == 0

    RateLimiter.check(key)
    assert RateLimiter.current_count(key) == 1
  end

  test "reset clears a key" do
    key = "ip-reset-#{System.unique_integer([:positive])}"
    for _ <- 1..3, do: RateLimiter.check(key)
    RateLimiter.reset(key)
    assert RateLimiter.current_count(key) == 0
  end
end
