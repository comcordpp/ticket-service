defmodule TicketService.Workers.ETicketEmailWorker do
  @moduledoc """
  Oban worker for reliable e-ticket email delivery.

  Generates e-tickets for a confirmed order and sends them via email.
  On successful delivery, marks tickets as delivered (sold -> delivered).
  Retries up to 3 times on failure with exponential backoff.
  """
  use Oban.Worker, queue: :emails, max_attempts: 3

  alias TicketService.{ETickets, Notifications, Repo}
  alias TicketService.Orders.Order

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"order_id" => order_id} = args}) do
    email = args["email"]
    name = args["name"]

    case Repo.get(Order, order_id) do
      nil ->
        {:error, "Order #{order_id} not found"}

      order ->
        order = Repo.preload(order, [:event, order_items: :ticket_type])

        # Check if tickets already exist (idempotent)
        existing_tickets = ETickets.list_tickets_for_order(order_id)

        tickets =
          if existing_tickets == [] do
            case ETickets.generate_for_order(order, email: email, name: name) do
              {:ok, tickets} -> tickets
              {:error, reason} -> raise "Failed to generate tickets: #{inspect(reason)}"
            end
          else
            existing_tickets
          end

        # Send email if we have a recipient
        if email do
          case Notifications.deliver_etickets(order, tickets) do
            {:ok, :delivered} ->
              ticket_ids = Enum.map(tickets, & &1.id)
              ETickets.mark_delivered(ticket_ids)
              :ok

            {:error, reason} ->
              raise "Email delivery failed: #{inspect(reason)}"
          end
        else
          :ok
        end
    end
  end
end
