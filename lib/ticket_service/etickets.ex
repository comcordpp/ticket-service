defmodule TicketService.ETickets do
  @moduledoc """
  E-Ticket context — generates QR-coded digital tickets for confirmed orders
  and handles ticket scanning/validation.
  """
  import Ecto.Query

  alias TicketService.Repo
  alias TicketService.Orders.Order
  alias TicketService.Tickets.Ticket

  @doc """
  Generate e-tickets for a confirmed order.

  Creates one Ticket record per individual ticket in each order item
  (e.g., quantity: 3 creates 3 Ticket records). Each ticket gets a
  unique token and QR code.

  Returns `{:ok, [%Ticket{}]}` or `{:error, reason}`.
  """
  def generate_for_order(%Order{id: order_id, event_id: event_id} = order, opts \\ []) do
    holder_email = Keyword.get(opts, :email)
    holder_name = Keyword.get(opts, :name)

    order = Repo.preload(order, :order_items)

    tickets =
      Enum.flat_map(order.order_items, fn item ->
        Enum.map(1..item.quantity, fn _i ->
          token = generate_token()
          qr_data = generate_qr_svg(token)

          %{
            token: token,
            qr_data: qr_data,
            holder_email: holder_email,
            holder_name: holder_name,
            status: "active",
            order_id: order_id,
            order_item_id: item.id,
            event_id: event_id,
            inserted_at: DateTime.utc_now() |> DateTime.truncate(:second),
            updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          }
        end)
      end)

    {count, inserted} = Repo.insert_all(Ticket, tickets, returning: true)

    if count > 0 do
      {:ok, inserted}
    else
      {:error, :no_tickets_generated}
    end
  end

  @doc """
  Validate a ticket by its token at scan time.

  Returns `{:ok, ticket}` if valid and marks it as used,
  or `{:error, reason}` if invalid/already used.
  """
  def scan_ticket(token) do
    case get_ticket_by_token(token) do
      nil ->
        {:error, :ticket_not_found}

      %Ticket{status: "used"} ->
        {:error, :already_scanned}

      %Ticket{status: "cancelled"} ->
        {:error, :ticket_cancelled}

      %Ticket{status: "active"} = ticket ->
        ticket
        |> Ticket.changeset(%{
          status: "used",
          scanned_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Repo.update()
    end
  end

  @doc "Get a ticket by its token."
  def get_ticket_by_token(token) do
    Ticket
    |> where([t], t.token == ^token)
    |> Repo.one()
    |> case do
      nil -> nil
      ticket -> Repo.preload(ticket, [:event, order: :order_items])
    end
  end

  @doc "List all tickets for an order."
  def list_tickets_for_order(order_id) do
    Ticket
    |> where([t], t.order_id == ^order_id)
    |> order_by([t], asc: t.inserted_at)
    |> Repo.all()
  end

  @doc "Cancel all tickets for an order (used during refunds)."
  def cancel_tickets_for_order(order_id) do
    from(t in Ticket,
      where: t.order_id == ^order_id and t.status == "active"
    )
    |> Repo.update_all(set: [status: "cancelled", updated_at: DateTime.utc_now() |> DateTime.truncate(:second)])
  end

  @doc "Mark tickets as emailed."
  def mark_emailed(ticket_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(t in Ticket, where: t.id in ^ticket_ids)
    |> Repo.update_all(set: [emailed_at: now, updated_at: now])
  end

  # --- Private ---

  defp generate_token do
    :crypto.strong_rand_bytes(20) |> Base.url_encode64(padding: false)
  end

  defp generate_qr_svg(token) do
    # Generate QR code as SVG string
    scan_url = ticket_scan_url(token)

    scan_url
    |> EQRCode.encode()
    |> EQRCode.svg(width: 300)
  end

  defp ticket_scan_url(token) do
    base_url = Application.get_env(:ticket_service, :base_url, "https://tickets.example.com")
    "#{base_url}/api/tickets/#{token}/scan"
  end
end
