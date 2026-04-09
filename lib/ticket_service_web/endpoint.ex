defmodule TicketServiceWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :ticket_service

  @session_options [
    store: :cookie,
    key: "_ticket_service_key",
    signing_salt: "ticket_svc",
    same_site: "Lax"
  ]

  socket "/socket", TicketServiceWeb.UserSocket,
    websocket: true,
    longpoll: false

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug TicketServiceWeb.Router
end
