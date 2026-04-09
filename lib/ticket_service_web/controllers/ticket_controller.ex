defmodule TicketServiceWeb.TicketController do
  use TicketServiceWeb, :controller

  alias TicketService.ETickets
  alias TicketService.Orders

  @doc """
  Validate a ticket by scanning its QR code token.

  POST /api/tickets/:token/scan
  """
  def scan(conn, %{"token" => token}) do
    case ETickets.scan_ticket(token) do
      {:ok, ticket} ->
        json(conn, %{
          data: %{
            ticket_id: ticket.id,
            status: "scanned",
            event_id: ticket.event_id,
            scanned_at: ticket.scanned_at
          }
        })

      {:error, :ticket_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Ticket not found"})

      {:error, :already_scanned} ->
        conn |> put_status(:conflict) |> json(%{error: "Ticket already scanned"})

      {:error, :ticket_cancelled} ->
        conn |> put_status(:gone) |> json(%{error: "Ticket has been cancelled"})
    end
  end

  @doc """
  Validate a ticket via HMAC-signed QR payload data.

  POST /api/tickets/validate
  Body: { "qr_data": "ticket_id:order_id:event_id:hmac" }

  Returns valid/invalid/already-scanned with ticket details.
  """
  def validate(conn, %{"qr_data" => qr_data}) do
    case ETickets.scan_by_qr(qr_data) do
      {:ok, ticket} ->
        ticket = TicketService.Repo.preload(ticket, :event)

        json(conn, %{
          data: %{
            result: "valid",
            ticket_id: ticket.id,
            event_id: ticket.event_id,
            order_id: ticket.order_id,
            status: ticket.status,
            event_title: ticket.event && ticket.event.title,
            holder_name: ticket.holder_name,
            scanned_at: ticket.scanned_at
          }
        })

      {:error, :already_scanned, ticket} ->
        conn
        |> put_status(:conflict)
        |> json(%{
          data: %{
            result: "already_scanned",
            ticket_id: ticket.id,
            event_id: ticket.event_id,
            status: ticket.status,
            scanned_at: ticket.scanned_at
          }
        })

      {:error, :ticket_cancelled, ticket} ->
        conn
        |> put_status(:gone)
        |> json(%{
          data: %{
            result: "invalid",
            reason: "ticket_cancelled",
            ticket_id: ticket.id
          }
        })

      {:error, :invalid_hmac} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{data: %{result: "invalid", reason: "tampered_qr_code"}})

      {:error, :invalid_qr_format} ->
        conn
        |> put_status(:bad_request)
        |> json(%{data: %{result: "invalid", reason: "invalid_qr_format"}})

      {:error, :ticket_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{data: %{result: "invalid", reason: "ticket_not_found"}})

      {:error, :invalid_ticket} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{data: %{result: "invalid", reason: "ticket_id_mismatch"}})
    end
  end

  def validate(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required field: qr_data"})
  end

  @doc """
  Look up a ticket by token (for verification without scanning).

  GET /api/tickets/:token
  """
  def show(conn, %{"token" => token}) do
    case ETickets.get_ticket_by_token(token) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Ticket not found"})

      ticket ->
        json(conn, %{
          data: %{
            id: ticket.id,
            token: ticket.token,
            status: ticket.status,
            event_id: ticket.event_id,
            holder_name: ticket.holder_name,
            holder_email: ticket.holder_email,
            scanned_at: ticket.scanned_at,
            delivered_at: ticket.delivered_at,
            created_at: ticket.inserted_at
          }
        })
    end
  end

  @doc """
  Get QR code as PNG image for a ticket.

  GET /api/tickets/:id/qr
  """
  def qr(conn, %{"id" => id}) do
    case ETickets.get_ticket(id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Ticket not found"})

      ticket ->
        png_data = ETickets.generate_qr_png(ticket)

        conn
        |> put_resp_content_type("image/png")
        |> send_resp(200, png_data)
    end
  end

  @doc """
  List all tickets for an order.

  GET /api/orders/:order_id/tickets
  """
  def index(conn, %{"order_id" => order_id}) do
    tickets = ETickets.list_tickets_for_order(order_id)

    json(conn, %{
      data: Enum.map(tickets, fn t ->
        %{
          id: t.id,
          token: t.token,
          status: t.status,
          holder_email: t.holder_email,
          scanned_at: t.scanned_at,
          emailed_at: t.emailed_at,
          delivered_at: t.delivered_at,
          created_at: t.inserted_at
        }
      end)
    })
  end

  @doc """
  Resend e-tickets for an order.

  POST /api/orders/:order_id/resend-tickets
  Body: { "email": "fan@example.com" }
  """
  def resend(conn, %{"order_id" => order_id} = params) do
    email = params["email"]

    case Orders.get_order(order_id) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "Order not found"})

      %{status: status} when status not in ["confirmed"] ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Order is not confirmed"})

      order ->
        # Use holder_email from existing tickets if not provided
        email = email || get_ticket_email(order.id)

        if is_nil(email) do
          conn |> put_status(:bad_request) |> json(%{error: "Email address required"})
        else
          case Orders.resend_tickets(order, email) do
            {:ok, :enqueued} ->
              json(conn, %{data: %{message: "E-tickets queued for re-delivery", order_id: order_id}})

            {:error, :no_tickets} ->
              conn |> put_status(:not_found) |> json(%{error: "No tickets found for this order"})
          end
        end
    end
  end

  defp get_ticket_email(order_id) do
    order_id
    |> ETickets.list_tickets_for_order()
    |> Enum.find_value(& &1.holder_email)
  end
end
