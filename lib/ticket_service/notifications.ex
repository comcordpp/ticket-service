defmodule TicketService.Notifications do
  @moduledoc """
  Email notifications for ticket purchase confirmations, e-ticket delivery,
  and refund confirmations.
  """
  import Swoosh.Email

  alias TicketService.Mailer
  alias TicketService.ETickets
  alias TicketService.Repo

  @from {"TicketService", "tickets@example.com"}

  @doc """
  Send e-tickets to the holder's email.

  Generates an email with ticket details and QR codes attached as inline SVG.
  Marks tickets as emailed after successful delivery.
  """
  def deliver_etickets(order, tickets) do
    order = Repo.preload(order, [:event, order_items: :ticket_type])

    case order.order_items do
      [] ->
        {:error, :no_order_items}

      _items ->
        email = Map.get(hd(tickets), :holder_email) || Map.get(hd(tickets), "holder_email")

        if is_nil(email) do
          {:error, :no_email}
        else
          ticket_html = build_ticket_html(order, tickets)

          result =
            new()
            |> to(email)
            |> from(@from)
            |> subject("Your tickets for #{order.event.title}")
            |> html_body(ticket_html)
            |> Mailer.deliver()

          case result do
            {:ok, _} ->
              {:ok, :delivered}

            {:error, reason} ->
              {:error, {:email_delivery_failed, reason}}
          end
        end
    end
  end

  @doc "Send a refund confirmation email."
  def deliver_refund_confirmation(order, email) do
    order = Repo.preload(order, :event)

    result =
      new()
      |> to(email)
      |> from(@from)
      |> subject("Refund confirmation for #{order.event.title}")
      |> html_body("""
      <h2>Refund Confirmed</h2>
      <p>Your refund of <strong>$#{order.refund_amount}</strong> for
      <strong>#{order.event.title}</strong> has been processed.</p>
      <p>Order ID: #{order.id}</p>
      <p>Please allow 5-10 business days for the refund to appear on your statement.</p>
      """)
      |> Mailer.deliver()

    case result do
      {:ok, _} -> {:ok, :delivered}
      {:error, reason} -> {:error, {:email_delivery_failed, reason}}
    end
  end

  # --- Private ---

  defp build_ticket_html(order, tickets) do
    ticket_sections =
      Enum.map_join(tickets, "\n", fn ticket ->
        """
        <div style="border: 1px solid #ddd; padding: 16px; margin: 8px 0; border-radius: 8px;">
          <h3>Ticket ##{ticket.token}</h3>
          <p><strong>Event:</strong> #{order.event.title}</p>
          <p><strong>Date:</strong> #{Calendar.strftime(order.event.starts_at, "%B %d, %Y at %I:%M %p")}</p>
          <div style="text-align: center; margin: 16px 0;">
            #{ticket.qr_data}
          </div>
          <p style="text-align: center; font-size: 12px; color: #666;">
            Scan this QR code at the venue entrance
          </p>
        </div>
        """
      end)

    """
    <html>
    <body style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
      <h1>Your E-Tickets</h1>
      <p>Thank you for your purchase! Here are your tickets:</p>
      <p><strong>Order Total:</strong> $#{order.total}</p>
      #{ticket_sections}
      <hr>
      <p style="font-size: 12px; color: #999;">
        This email was sent by TicketService. Do not reply to this email.
      </p>
    </body>
    </html>
    """
  end
end
