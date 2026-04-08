defmodule TicketService.Repo do
  use Ecto.Repo,
    otp_app: :ticket_service,
    adapter: Ecto.Adapters.Postgres
end
