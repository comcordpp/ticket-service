import Config

config :ticket_service, TicketService.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "ticket_service_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

config :ticket_service, TicketServiceWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_only_secret_key_base_that_is_at_least_64_bytes_long_for_phoenix_to_work_properly_ok",
  server: false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime

# Oban: inline testing mode
config :ticket_service, Oban, testing: :inline
