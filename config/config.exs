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

# Rate limiter configuration
config :ticket_service, TicketService.AntiBot.RateLimiter,
  ip_limit: 60,
  ip_window_ms: 60_000,
  session_limit: 30,
  session_window_ms: 60_000,
  endpoints: %{
    "purchase" => %{ip_limit: 60, session_limit: 30, window_ms: 60_000},
    "cart_add" => %{ip_limit: 30, session_limit: 15, window_ms: 60_000},
    "checkout" => %{ip_limit: 10, session_limit: 5, window_ms: 60_000}
  },
  event_overrides: %{},
  allowlist: [],
  blocklist: []

# Bot detection configuration
config :ticket_service, TicketService.AntiBot.Detector,
  captcha_threshold: 60,
  block_threshold: 90,
  velocity_threshold_ms: 500,
  session_ttl_ms: 1_800_000

# CAPTCHA provider configuration
config :ticket_service, TicketService.AntiBot.CaptchaProvider,
  provider: TicketService.AntiBot.CaptchaProvider.Noop,
  site_key: System.get_env("CAPTCHA_SITE_KEY") || "test-site-key",
  secret_key: System.get_env("CAPTCHA_SECRET_KEY") || "test-secret-key"

# Stripe configuration
config :stripity_stripe,
  api_key: System.get_env("STRIPE_SECRET_KEY") || "sk_test_placeholder"

config :ticket_service,
  stripe_webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET") || "whsec_test_placeholder",
  base_url: System.get_env("BASE_URL") || "http://localhost:4000",
  qr_hmac_secret: System.get_env("QR_HMAC_SECRET") || "dev_hmac_secret_change_in_prod"

# Oban job queue
config :ticket_service, Oban,
  repo: TicketService.Repo,
  queues: [default: 10, emails: 5]

# Email configuration (Swoosh)
config :ticket_service, TicketService.Mailer,
  adapter: Swoosh.Adapters.Local

config :swoosh, :api_client, false

import_config "#{config_env()}.exs"
