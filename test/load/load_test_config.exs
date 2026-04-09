# Load Testing Configuration
#
# This module provides load test scenarios for validating system performance
# under high concurrency. Target: 100K+ concurrent users.
#
# Run with: mix run test/load/load_test_config.exs
#
# For production load testing, use a dedicated tool like k6, Locust, or Tsung.
# This config provides the scenario definitions and target metrics.

defmodule TicketService.LoadTest.Config do
  @moduledoc """
  Load test scenarios and target metrics for the Ticket Service.

  ## Target Metrics (100K concurrent users)
  - Cart operations: p99 < 200ms
  - Checkout: p99 < 500ms
  - Seat map WebSocket: update broadcast < 500ms
  - Queue system: handle 10K req/sec throughput
  - Bot detection: < 5ms per analysis
  """

  def scenarios do
    [
      %{
        name: "ticket_rush",
        description: "Simulate a popular event on-sale with 100K concurrent buyers",
        stages: [
          %{duration_sec: 30, target_vus: 1_000},    # Ramp up
          %{duration_sec: 60, target_vus: 10_000},   # Steady state
          %{duration_sec: 120, target_vus: 100_000},  # Peak load
          %{duration_sec: 60, target_vus: 50_000},   # Cool down
          %{duration_sec: 30, target_vus: 0}          # Ramp down
        ],
        flow: [
          :join_queue,
          :wait_for_pass,
          :view_seat_map,
          :add_to_cart,
          :checkout,
          :pay
        ]
      },
      %{
        name: "bot_attack",
        description: "Simulate bot attack with rapid automated requests",
        stages: [
          %{duration_sec: 10, target_vus: 5_000},
          %{duration_sec: 60, target_vus: 50_000},
          %{duration_sec: 10, target_vus: 0}
        ],
        flow: [
          :rapid_cart_adds,
          :rapid_checkouts
        ]
      },
      %{
        name: "websocket_stress",
        description: "Stress test WebSocket connections for seat map and dashboard",
        stages: [
          %{duration_sec: 30, target_vus: 10_000},
          %{duration_sec: 120, target_vus: 50_000},
          %{duration_sec: 30, target_vus: 0}
        ],
        flow: [
          :connect_seat_map,
          :connect_dashboard,
          :receive_updates
        ]
      }
    ]
  end

  def target_metrics do
    %{
      cart_add_p99_ms: 200,
      checkout_p99_ms: 500,
      seat_map_broadcast_ms: 500,
      queue_throughput_rps: 10_000,
      bot_detection_p99_ms: 5,
      websocket_connect_p99_ms: 100,
      payment_intent_p99_ms: 2_000,
      error_rate_percent: 0.1
    }
  end

  def genserver_supervision_chaos do
    %{
      description: "Chaos testing for GenServer supervision trees",
      tests: [
        %{
          name: "cart_server_crash",
          action: "Kill random CartServer processes",
          expectation: "DynamicSupervisor restarts, state recovered from ETS/DB"
        },
        %{
          name: "queue_crash",
          action: "Kill FairQueue process mid-operation",
          expectation: "QueueSupervisor restarts, queue state rebuilt"
        },
        %{
          name: "rate_limiter_crash",
          action: "Kill RateLimiter GenServer",
          expectation: "Supervisor restarts, ETS table rebuilt, brief window of no limiting"
        },
        %{
          name: "detector_crash",
          action: "Kill Detector GenServer",
          expectation: "Supervisor restarts, sessions cleared, brief window of no detection"
        },
        %{
          name: "analytics_crash",
          action: "Kill Analytics GenServer",
          expectation: "Supervisor restarts, recent metrics lost (acceptable), no data corruption"
        }
      ]
    }
  end
end

IO.puts("Load test configuration loaded.")
IO.puts("Scenarios: #{length(TicketService.LoadTest.Config.scenarios())}")
IO.puts("Target metrics: #{inspect(TicketService.LoadTest.Config.target_metrics())}")
