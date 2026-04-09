defmodule TicketServiceWeb.Router do
  use TicketServiceWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :rate_limited do
    plug TicketServiceWeb.Plugs.RateLimit, endpoint: "purchase"
  end

  pipeline :rate_limited_cart do
    plug TicketServiceWeb.Plugs.RateLimit, endpoint: "cart_add"
  end

  pipeline :rate_limited_checkout do
    plug TicketServiceWeb.Plugs.RateLimit, endpoint: "checkout"
  end

  pipeline :bot_guarded do
    plug TicketServiceWeb.Plugs.BotGuard
  end

  scope "/api", TicketServiceWeb do
    pipe_through :api

    # Venues
    resources "/venues", VenueController, except: [:new, :edit] do
      # Sections nested under venues
      resources "/sections", SectionController, only: [:index, :create]
    end

    # Sections (direct access)
    resources "/sections", SectionController, only: [:show, :update, :delete] do
      get "/seats", SectionController, :seats
    end

    # Events
    resources "/events", EventController, except: [:new, :edit] do
      # Lifecycle actions
      post "/publish", EventController, :publish
      post "/cancel", EventController, :cancel

      # Ticket types nested under events
      resources "/ticket_types", TicketTypeController, only: [:index, :create]

      # Promo codes nested under events
      resources "/promo_codes", PromoCodeController, only: [:index, :create]
      post "/promo_codes/validate", PromoCodeController, :validate
    end

    # Direct access to ticket types and promo codes
    resources "/ticket_types", TicketTypeController, only: [:show, :update, :delete]
    resources "/promo_codes", PromoCodeController, only: [:show, :update, :delete]

    # Organizers
    resources "/organizers", OrganizerController, except: [:new, :edit, :delete] do
      post "/connect", OrganizerController, :create_connect_account
      post "/onboarding-link", OrganizerController, :onboarding_link
      post "/refresh-status", OrganizerController, :refresh_status
    end

    # Carts (read-only — standard rate limit)
    get "/carts/:session_id", CartController, :show
    get "/carts/:session_id/pricing", PricingController, :show

    # Orders (read-only)
    get "/orders/token/:token", CheckoutController, :show
    get "/orders/:order_id/refunds", PaymentController, :index

    # E-Ticket endpoints
    get "/orders/:order_id/tickets", TicketController, :index
    post "/orders/:order_id/resend-tickets", TicketController, :resend
    post "/tickets/validate", TicketController, :validate
    get "/tickets/:id/qr", TicketController, :qr
    get "/tickets/:token", TicketController, :show
    post "/tickets/:token/scan", TicketController, :scan

    # Order management
    get "/orders/search", OrderController, :search
    get "/orders/:id", OrderController, :show

    # Analytics
    get "/events/:event_id/analytics", AnalyticsController, :snapshot
    get "/events/:event_id/analytics/timeseries/:metric", AnalyticsController, :timeseries
    post "/events/:event_id/analytics/alerts", AnalyticsController, :set_alert

    # Queue system
    post "/events/:event_id/queue/join", QueueController, :join
    get "/events/:event_id/queue/position/:session_id", QueueController, :position
    # Legacy routes (backward compat)
    post "/events/:event_id/queue/access", QueueController, :request_access
    get "/events/:event_id/queue/status", QueueController, :status

    # Admin queue stats
    get "/admin/events/:event_id/queue/stats", QueueController, :stats

    # Admin bot detection
    get "/admin/bot-detection/stats", BotDetectionController, :stats
    get "/admin/bot-detection/audit-log", BotDetectionController, :audit_log
    get "/admin/bot-detection/rules", BotDetectionController, :index_rules
    post "/admin/bot-detection/rules", BotDetectionController, :create_rule
    delete "/admin/bot-detection/rules/:id", BotDetectionController, :delete_rule

    # CAPTCHA verification
    post "/captcha/verify", CaptchaController, :verify

    # Public listing
    get "/public/events", EventController, :index
  end

  # Rate-limited and bot-guarded cart mutation endpoints
  scope "/api", TicketServiceWeb do
    pipe_through [:api, :rate_limited_cart, :bot_guarded]

    post "/carts/:session_id/items", CartController, :add_item
    delete "/carts/:session_id/items/:ticket_type_id", CartController, :remove_item
    patch "/carts/:session_id/items/:ticket_type_id", CartController, :update_item
    delete "/carts/:session_id", CartController, :clear
  end

  # Rate-limited and bot-guarded checkout and payment endpoints
  scope "/api", TicketServiceWeb do
    pipe_through [:api, :rate_limited_checkout, :bot_guarded]

    get "/carts/:session_id/review", CheckoutController, :review
    post "/carts/:session_id/checkout", CheckoutController, :create
    post "/orders/token/:token/confirm", CheckoutController, :confirm
    post "/orders/token/:token/pay", PaymentController, :create_intent
    post "/orders/:id/refund", PaymentController, :refund
  end

  # Stripe webhook — outside API pipeline (needs raw body for signature verification)
  scope "/webhooks", TicketServiceWeb do
    post "/stripe", WebhookController, :stripe
  end

  if Application.compile_env(:ticket_service, :dev_routes, false) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]
      live_dashboard "/dashboard", metrics: TicketServiceWeb.Telemetry
    end
  end
end
