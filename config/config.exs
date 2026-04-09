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

# Stripe configuration
config :stripity_stripe,
  api_key: System.get_env("STRIPE_SECRET_KEY") || "sk_test_placeholder"

config :ticket_service,
  stripe_webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET") || "whsec_test_placeholder",
  base_url: System.get_env("BASE_URL") || "http://localhost:4000"

# Email configuration (Swoosh)
config :ticket_service, TicketService.Mailer,
  adapter: Swoosh.Adapters.Local

config :swoosh, :api_client, false

import_config "#{config_env()}.exs"
