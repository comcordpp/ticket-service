import Config

config :ticket_service,
  ecto_repos: [TicketService.Repo],
  generators: [timestamp_type: :utc_datetime]

config :ticket_service, TicketServiceWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: TicketServiceWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: TicketService.PubSub,
  live_view: [signing_salt: "ticket_svc"]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
