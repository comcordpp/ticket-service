defmodule TicketServiceWeb.TicketController do
  use TicketServiceWeb, :controller

  alias TicketService.ETickets

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
            status: "used",
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
            scanned_at: ticket.scanned_at,
            created_at: ticket.inserted_at
          }
        })
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
          created_at: t.inserted_at
        }
      end)
    })
  end
end
