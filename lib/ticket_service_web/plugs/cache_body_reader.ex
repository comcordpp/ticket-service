defmodule TicketServiceWeb.CacheBodyReader do
  @moduledoc """
  Caches the raw request body for Stripe webhook signature verification.
  Used only on the webhook route.
  """

  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    conn = Plug.Conn.assign(conn, :raw_body, body)
    {:ok, body, conn}
  end
end
