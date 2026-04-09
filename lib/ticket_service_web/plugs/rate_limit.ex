defmodule TicketServiceWeb.Plugs.RateLimit do
  @moduledoc """
  Plug that enforces per-IP rate limiting using the RateLimiter module.

  Usage in router:

      plug TicketServiceWeb.Plugs.RateLimit, endpoint: "cart_add"
  """
  import Plug.Conn

  alias TicketService.AntiBot.RateLimiter

  def init(opts), do: opts

  def call(conn, opts) do
    endpoint = Keyword.get(opts, :endpoint, "default")
    key = client_ip(conn)

    case RateLimiter.check(key, endpoint) do
      :ok ->
        conn

      {:error, :rate_limited, retry_after_ms} ->
        retry_after_secs = max(div(retry_after_ms, 1000), 1)

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after_secs))
        |> put_status(429)
        |> Phoenix.Controller.json(%{
          error: "Too many requests",
          retry_after: retry_after_secs
        })
        |> halt()
    end
  end

  defp client_ip(conn) do
    # Check X-Forwarded-For first for proxied requests
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded |> String.split(",") |> List.first() |> String.trim()

      [] ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
