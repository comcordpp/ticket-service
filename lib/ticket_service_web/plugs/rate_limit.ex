defmodule TicketServiceWeb.Plugs.RateLimit do
  @moduledoc """
  Plug that enforces per-IP and per-session rate limiting.

  Applies both IP-based and session-based rate limits. Returns HTTP 429 with
  `Retry-After` header when limits are exceeded. Adds standard rate limit headers
  (`X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`) to all responses.

  Supports IP allowlist/blocklist and per-event overrides for high-demand events.

  ## Usage in router

      plug TicketServiceWeb.Plugs.RateLimit, endpoint: "cart_add"
      plug TicketServiceWeb.Plugs.RateLimit, endpoint: "checkout", event_id_param: "event_id"
  """
  import Plug.Conn
  require Logger

  alias TicketService.AntiBot.RateLimiter

  def init(opts), do: opts

  def call(conn, opts) do
    endpoint = Keyword.get(opts, :endpoint, "default")
    ip = client_ip(conn)

    cond do
      RateLimiter.allowlisted?(ip) ->
        conn

      RateLimiter.blocklisted?(ip) ->
        log_violation(ip, nil, endpoint, :blocklisted)

        conn
        |> put_status(403)
        |> Phoenix.Controller.json(%{
          error: "Forbidden",
          message: "Your IP address has been blocked."
        })
        |> halt()

      true ->
        event_id = extract_event_id(conn, opts)
        check_opts = if event_id, do: [event_id: event_id], else: []

        conn
        |> check_ip_limit(ip, endpoint, check_opts)
        |> check_session_limit(endpoint, check_opts)
    end
  end

  defp check_ip_limit(conn, ip, endpoint, check_opts) do
    if conn.halted do
      conn
    else
      case RateLimiter.check(ip, endpoint, check_opts) do
        {:ok, info} ->
          put_rate_limit_headers(conn, info)

        {:error, :rate_limited, info} ->
          log_violation(ip, nil, endpoint, :ip_rate_limited)
          reject(conn, info)
      end
    end
  end

  defp check_session_limit(conn, endpoint, check_opts) do
    if conn.halted do
      conn
    else
      session_id = extract_session_id(conn)

      if session_id do
        session_key = {:session, session_id}

        case RateLimiter.check(session_key, endpoint, check_opts) do
          {:ok, info} ->
            merge_rate_limit_headers(conn, info)

          {:error, :rate_limited, info} ->
            ip = client_ip(conn)
            log_violation(ip, session_id, endpoint, :session_rate_limited)
            reject(conn, info)
        end
      else
        conn
      end
    end
  end

  defp put_rate_limit_headers(conn, info) do
    reset_secs = max(div(info.reset_ms, 1000), 1)

    conn
    |> put_resp_header("x-ratelimit-limit", Integer.to_string(info.limit))
    |> put_resp_header("x-ratelimit-remaining", Integer.to_string(max(info.remaining, 0)))
    |> put_resp_header("x-ratelimit-reset", Integer.to_string(reset_secs))
  end

  defp merge_rate_limit_headers(conn, info) do
    # Use the more restrictive (lower remaining) of IP vs session limits
    existing_remaining =
      case get_resp_header(conn, "x-ratelimit-remaining") do
        [val | _] -> String.to_integer(val)
        [] -> info.remaining
      end

    if info.remaining < existing_remaining do
      put_rate_limit_headers(conn, info)
    else
      conn
    end
  end

  defp reject(conn, info) do
    retry_after_secs = max(div(info.retry_after_ms, 1000), 1)
    reset_at = DateTime.utc_now() |> DateTime.add(retry_after_secs, :second) |> DateTime.to_iso8601()

    conn
    |> put_resp_header("retry-after", Integer.to_string(retry_after_secs))
    |> put_resp_header("x-ratelimit-limit", Integer.to_string(info.limit))
    |> put_resp_header("x-ratelimit-remaining", "0")
    |> put_resp_header("x-ratelimit-reset", Integer.to_string(retry_after_secs))
    |> put_status(429)
    |> Phoenix.Controller.json(%{
      error: "Too Many Requests",
      message: "Rate limit exceeded. Please wait before retrying.",
      retry_after: retry_after_secs,
      retry_at: reset_at
    })
    |> halt()
  end

  defp log_violation(ip, session_id, endpoint, reason) do
    Logger.warning("Rate limit violation",
      ip: ip,
      session_id: session_id,
      endpoint: endpoint,
      reason: reason,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    )
  end

  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded |> String.split(",") |> List.first() |> String.trim()

      [] ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end

  defp extract_session_id(conn) do
    # Check path params first (for cart/checkout routes), then query params
    conn.path_params["session_id"] || conn.params["session_id"]
  end

  defp extract_event_id(conn, opts) do
    param = Keyword.get(opts, :event_id_param, "event_id")
    conn.path_params[param] || conn.params[param]
  end
end
