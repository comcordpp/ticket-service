# Ticket Service

A full-featured event ticketing platform built with Elixir and Phoenix. Handles event management, ticket sales, seat reservations, payments (Stripe), real-time occupancy tracking, and anti-bot protection.

## Architecture

```
                            ┌─────────────────────────┐
                            │     Phoenix Endpoint     │
                            │    (localhost:4000)       │
                            └────────┬────────────────┘
                                     │
                 ┌───────────────────┼──────────────────┐
                 │                   │                   │
          REST Controllers     LiveView          WebSocket Channels
          (JSON API)       (Occupancy UI)       (Real-time updates)
                 │                   │                   │
                 └───────────────────┼──────────────────┘
                                     │
     ┌──────────┬──────────┬─────────┼──────────┬──────────────┐
     │          │          │         │          │              │
   Events    Venues    Seating    Carts    Payments       Anti-Bot
     │          │      (optimistic  │     (Stripe)     (rate limit,
   Tickets   Sections   locking)  Checkout               CAPTCHA)
     │                             │          │
   E-tickets                     Orders    Refunds
   (QR codes)                      │
                                 Oban Jobs
                              (emails, async)
                                   │
                              PostgreSQL
```

### Key Modules

| Module | Purpose |
|--------|---------|
| `TicketService.Events` | Event lifecycle (create, edit, cancel, publish) |
| `TicketService.Venues` | Venue and capacity management |
| `TicketService.Seating` | Seat reservation with optimistic locking |
| `TicketService.Carts` | Shopping cart (DynamicSupervisor-managed) |
| `TicketService.Checkout` | End-to-end checkout flow |
| `TicketService.Payments` | Stripe integration and webhook handling |
| `TicketService.Orders` | Order creation and management |
| `TicketService.AntiBot` | Rate limiting, bot detection, CAPTCHA |
| `TicketService.Occupancy` | Real-time occupancy counters and snapshots |
| `TicketService.Etickets` | QR code generation with HMAC verification |
| `TicketService.Workers` | Oban background jobs (emails, async tasks) |

## Prerequisites

- **Elixir** >= 1.17
- **Erlang/OTP** >= 27
- **PostgreSQL** >= 15

Verify your installation:

```bash
elixir --version    # Should show Elixir 1.17+
psql --version      # Should show 15+
```

## Getting Started

### 1. Install Dependencies

```bash
mix deps.get
```

### 2. Set Up the Database

The development database defaults to `ticket_service_dev` on `localhost:5432` with `postgres`/`postgres` credentials. If your local PostgreSQL uses different credentials, set them in `config/dev.exs` or export env vars before proceeding.

```bash
# Create database, run migrations, and seed sample data
mix ecto.setup
```

This runs:
- `mix ecto.create` — creates the `ticket_service_dev` database
- `mix ecto.migrate` — applies all schema migrations (venues, events, sections, seats, ticket types, promo codes, orders, tickets, fee configs, refunds, occupancy snapshots, organizers, e-ticket enhancements)
- `mix run priv/repo/seeds.exs` — seeds sample data

### 3. Start the Server

```bash
mix phx.server
```

Visit [http://localhost:4000](http://localhost:4000).

The Phoenix Live Dashboard is available at [http://localhost:4000/dev/dashboard](http://localhost:4000/dev/dashboard) for monitoring processes, memory, and Oban queues.

## Running Tests

### Full Test Suite

```bash
# Ensure test database is set up
MIX_ENV=test mix ecto.setup

# Run all tests
mix test
```

### Running Specific Tests

```bash
# Run a single test file
mix test test/ticket_service/checkout_test.exs

# Run tests matching a pattern
mix test --only pricing

# Run with verbose output
mix test --trace
```

### Test Categories

| Category | Files | What They Cover |
|----------|-------|-----------------|
| **Checkout** | `checkout_test.exs` | End-to-end purchase flow |
| **Pricing** | `pricing_test.exs` | Fee calculations, promo codes |
| **Seating** | `seat_reservation_test.exs` | Optimistic locking, concurrent reservations |
| **Analytics** | `analytics_test.exs` | Revenue and occupancy calculations |
| **Anti-Bot** | `anti_bot/detector_test.exs`, `rate_limiter_test.exs`, `captcha_provider_test.exs` | Bot detection, rate limits, CAPTCHA |
| **Queue** | `queue/fair_queue_test.exs` | Fair queue system |
| **Occupancy** | `occupancy/counter_test.exs` | Real-time counters |
| **Controllers** | `ticket_service_web/controllers/*` | REST API endpoints |
| **LiveView** | `occupancy_live_test.exs` | Real-time occupancy UI |
| **Plugs** | `rate_limit_test.exs`, `bot_guard_test.exs` | Middleware |

Tests use Ecto sandbox mode for database isolation, so they can run concurrently.

## Environment Variables

### Development (defaults provided — no setup required)

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | `localhost:5432/ticket_service_dev` | PostgreSQL connection (configured in `dev.exs`) |
| `STRIPE_SECRET_KEY` | _(optional in dev)_ | Stripe API key for payment testing |
| `STRIPE_WEBHOOK_SECRET` | _(optional in dev)_ | Stripe webhook signature verification |
| `CAPTCHA_SITE_KEY` | _(optional)_ | CAPTCHA provider site key (no-op in dev) |
| `CAPTCHA_SECRET_KEY` | _(optional)_ | CAPTCHA provider secret key |
| `QR_HMAC_SECRET` | _(optional)_ | Secret for QR code HMAC signatures |

### Production (required)

| Variable | Description |
|----------|-------------|
| `DATABASE_URL` | Full PostgreSQL connection string (`ecto://user:pass@host/db`) |
| `SECRET_KEY_BASE` | Phoenix secret (min 64 bytes, generate with `mix phx.gen.secret`) |
| `PHX_HOST` | Public hostname (e.g., `tickets.example.com`) |
| `PORT` | HTTP port (default: `4000`) |
| `STRIPE_SECRET_KEY` | Live Stripe API key |
| `STRIPE_WEBHOOK_SECRET` | Live webhook signing secret |

## API Endpoints

The service exposes a JSON REST API. Key endpoint groups:

| Prefix | Description |
|--------|-------------|
| `GET/POST /api/events` | Event CRUD |
| `GET/POST /api/venues` | Venue management |
| `GET/POST /api/carts` | Cart operations |
| `POST /api/checkout` | Purchase flow |
| `GET /api/orders` | Order lookup |
| `GET /api/occupancy` | Real-time occupancy data |
| `POST /api/webhooks/stripe` | Stripe webhook receiver |

Use the Live Dashboard at `/dev/dashboard` to inspect routes, processes, and Oban job queues during development.

## Database

### Reset

```bash
# Drop, recreate, migrate, and seed
mix ecto.reset
```

### Migrations Only

```bash
mix ecto.migrate

# Rollback last migration
mix ecto.rollback
```

### Schema Overview

The database includes tables for: venues, events, sections, seats (with `lock_version` for optimistic concurrency), ticket types, promo codes, orders, tickets (with Stripe charge IDs and QR HMAC support), fee configs, refunds, occupancy snapshots, and organizers.

## Code Quality

```bash
# Format code
mix format

# Static analysis
mix credo --strict

# Compile with warnings as errors
mix compile --warnings-as-errors
```

## Project Structure

```
ticket_service/
├── config/
│   ├── config.exs          # Base configuration
│   ├── dev.exs             # Development settings
│   ├── test.exs            # Test settings
│   └── runtime.exs         # Production runtime config
├── lib/
│   ├── ticket_service/     # Core business logic
│   │   ├── anti_bot/       # Rate limiting, bot detection, CAPTCHA
│   │   ├── carts/          # Shopping cart (DynamicSupervisor)
│   │   ├── events/         # Event management
│   │   ├── occupancy/      # Real-time occupancy tracking
│   │   ├── orders/         # Order processing
│   │   ├── organizers/     # Organizer management
│   │   ├── payments/       # Stripe integration
│   │   ├── pricing/        # Dynamic pricing, fees
│   │   ├── queue/          # Fair queue (anti-scalping)
│   │   ├── realtime/       # PubSub messaging
│   │   ├── seating/        # Seat reservation
│   │   ├── tickets/        # Ticket and e-ticket generation
│   │   ├── venues/         # Venue management
│   │   └── workers/        # Oban background jobs
│   └── ticket_service_web/ # Phoenix web layer
│       ├── controllers/    # REST API controllers
│       ├── live/           # LiveView (occupancy UI)
│       ├── channels/       # WebSocket channels
│       └── plugs/          # Middleware (rate limit, bot guard)
├── priv/
│   └── repo/
│       ├── migrations/     # Database migrations
│       └── seeds.exs       # Sample data
└── test/
    ├── ticket_service/     # Business logic tests
    ├── ticket_service_web/ # Web layer tests
    └── support/            # Test helpers
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `(Postgrex.Error) FATAL: database "ticket_service_dev" does not exist` | Run `mix ecto.create` |
| Port 4000 already in use | `PORT=4001 mix phx.server` or kill the process on 4000 |
| `(Postgrex.Error) FATAL: password authentication failed` | Check PostgreSQL credentials in `config/dev.exs` |
| Stripe webhooks not working locally | Use [Stripe CLI](https://stripe.com/docs/stripe-cli) to forward: `stripe listen --forward-to localhost:4000/api/webhooks/stripe` |
| Oban jobs not processing | Check the Live Dashboard at `/dev/dashboard` → Oban tab |

## License

Proprietary. All rights reserved.
