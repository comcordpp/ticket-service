defmodule TicketService.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TicketServiceWeb.Telemetry,
      TicketService.Repo,
      {Oban, Application.fetch_env!(:ticket_service, Oban)},
      {DNSCluster, query: Application.get_env(:ticket_service, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: TicketService.PubSub},
      {Registry, keys: :unique, name: TicketService.CartRegistry},
      {DynamicSupervisor, name: TicketService.CartSupervisor, strategy: :one_for_one},
      # Queue system
      {Registry, keys: :unique, name: TicketService.QueueRegistry},
      {DynamicSupervisor, name: TicketService.QueueSupervisor, strategy: :one_for_one},
      # Anti-bot
      TicketService.AntiBot.RateLimiter,
      TicketService.AntiBot.Detector,
      # Analytics
      TicketService.Analytics,
      TicketServiceWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: TicketService.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    TicketServiceWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
