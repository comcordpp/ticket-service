defmodule TicketService.ETickets do
  @moduledoc """
  E-Ticket context — generates HMAC-signed QR-coded digital tickets for confirmed orders
  and handles ticket scanning/validation.

  QR payload format: ticket_id:order_id:event_id:hmac_signature
  The HMAC-SHA256 signature ensures tamper detection at scan time.

  Status transitions: sold -> delivered (email sent) -> scanned (at venue)
  """
  import Ecto.Query

  alias TicketService.Repo
  alias TicketService.Orders.Order
  alias TicketService.Tickets.Ticket

  @doc """
  Generate e-tickets for a confirmed order.

  Creates one Ticket record per individual ticket in each order item
  (e.g., quantity: 3 creates 3 Ticket records). Each ticket gets a
  unique token, HMAC-signed QR payload, and QR code.

  Returns `{:ok, [%Ticket{}]}` or `{:error, reason}`.
  """
  def generate_for_order(%Order{id: order_id, event_id: event_id} = order, opts \\ []) do
    holder_email = Keyword.get(opts, :email)
    holder_name = Keyword.get(opts, :name)

    order = Repo.preload(order, :order_items)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    tickets =
      Enum.flat_map(order.order_items, fn item ->
        Enum.map(1..item.quantity, fn _i ->
          ticket_id = Ecto.UUID.generate()
          token = generate_token()
          qr_payload = build_qr_payload(ticket_id, order_id, event_id)
          qr_hash = hash_payload(qr_payload)
          qr_svg = generate_qr_svg(qr_payload)

          %{
            id: ticket_id,
            token: token,
            qr_data: qr_svg,
            qr_hash: qr_hash,
            qr_payload: qr_payload,
            holder_email: holder_email,
            holder_name: holder_name,
            status: "sold",
            order_id: order_id,
            order_item_id: item.id,
            event_id: event_id,
            inserted_at: now,
            updated_at: now
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
  Validate a ticket by its scanned QR payload data.

  Verifies the HMAC signature, checks ticket status, and returns validation result.
  Does NOT mark the ticket as scanned — use `scan_ticket/1` for that.
  """
  def validate_qr(qr_payload) do
    with {:ok, {ticket_id, order_id, event_id}} <- parse_qr_payload(qr_payload),
         :ok <- verify_hmac(qr_payload),
         qr_hash = hash_payload(qr_payload),
         %Ticket{} = ticket <- get_ticket_by_qr_hash(qr_hash) do
      cond do
        ticket.status == "scanned" ->
          {:error, :already_scanned, ticket}

        ticket.status == "cancelled" ->
          {:error, :ticket_cancelled, ticket}

        ticket.id != ticket_id ->
          {:error, :invalid_ticket}

        true ->
          {:ok, ticket}
      end
    else
      nil -> {:error, :ticket_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Scan a ticket by its token (direct scan at venue).

  Marks the ticket as scanned (single-use). Returns error if already scanned.
  """
  def scan_ticket(token) do
    case get_ticket_by_token(token) do
      nil ->
        {:error, :ticket_not_found}

      %Ticket{status: "scanned"} ->
        {:error, :already_scanned}

      %Ticket{status: "cancelled"} ->
        {:error, :ticket_cancelled}

      %Ticket{status: status} = ticket when status in ["sold", "delivered"] ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        ticket
        |> Ticket.changeset(%{status: "scanned", scanned_at: now})
        |> Repo.update()
    end
  end

  @doc "Scan and validate a ticket via QR payload data (HMAC-verified venue scan)."
  def scan_by_qr(qr_payload) do
    case validate_qr(qr_payload) do
      {:ok, ticket} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        ticket
        |> Ticket.changeset(%{status: "scanned", scanned_at: now})
        |> Repo.update()

      {:error, :already_scanned, ticket} ->
        {:error, :already_scanned, ticket}

      error ->
        error
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

  @doc "Get a ticket by its QR hash (for HMAC-based validation lookup)."
  def get_ticket_by_qr_hash(qr_hash) do
    Ticket
    |> where([t], t.qr_hash == ^qr_hash)
    |> Repo.one()
    |> case do
      nil -> nil
      ticket -> Repo.preload(ticket, [:event, order: :order_items])
    end
  end

  @doc "Get a ticket by ID."
  def get_ticket(id) do
    Repo.get(Ticket, id)
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

  @doc """
  Mark tickets as delivered (email sent successfully).
  Transitions status from sold -> delivered.
  """
  def mark_delivered(ticket_ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(t in Ticket, where: t.id in ^ticket_ids and t.status == "sold")
    |> Repo.update_all(set: [
      status: "delivered",
      emailed_at: now,
      delivered_at: now,
      updated_at: now
    ])
  end

  @doc "Cancel all active tickets for an order (used during refunds)."
  def cancel_tickets_for_order(order_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(t in Ticket,
      where: t.order_id == ^order_id and t.status in ["sold", "delivered"]
    )
    |> Repo.update_all(set: [status: "cancelled", updated_at: now])
  end

  @doc "Generate a QR code as PNG binary for a ticket."
  def generate_qr_png(ticket) do
    payload = ticket.qr_payload || build_qr_payload(ticket.id, ticket.order_id, ticket.event_id)

    payload
    |> EQRCode.encode()
    |> EQRCode.png(width: 300)
  end

  @doc "Generate a QR code as SVG string for a ticket."
  def generate_qr_svg_for_ticket(ticket) do
    payload = ticket.qr_payload || build_qr_payload(ticket.id, ticket.order_id, ticket.event_id)
    generate_qr_svg(payload)
  end

  # --- HMAC / QR Payload ---

  @doc """
  Build the QR payload string: ticket_id:order_id:event_id:hmac
  """
  def build_qr_payload(ticket_id, order_id, event_id) do
    data = "#{ticket_id}:#{order_id}:#{event_id}"
    hmac = compute_hmac(data)
    "#{data}:#{hmac}"
  end

  @doc "Parse a QR payload, returning {ticket_id, order_id, event_id} or error."
  def parse_qr_payload(payload) when is_binary(payload) do
    case String.split(payload, ":") do
      [ticket_id, order_id, event_id, _hmac] ->
        {:ok, {ticket_id, order_id, event_id}}

      _ ->
        {:error, :invalid_qr_format}
    end
  end

  @doc "Verify the HMAC signature in a QR payload."
  def verify_hmac(payload) do
    case String.split(payload, ":") do
      [ticket_id, order_id, event_id, provided_hmac] ->
        data = "#{ticket_id}:#{order_id}:#{event_id}"
        expected_hmac = compute_hmac(data)

        if Plug.Crypto.secure_compare(expected_hmac, provided_hmac) do
          :ok
        else
          {:error, :invalid_hmac}
        end

      _ ->
        {:error, :invalid_qr_format}
    end
  end

  # --- Private ---

  defp generate_token do
    :crypto.strong_rand_bytes(20) |> Base.url_encode64(padding: false)
  end

  defp generate_qr_svg(payload) do
    payload
    |> EQRCode.encode()
    |> EQRCode.svg(width: 300)
  end

  defp compute_hmac(data) do
    secret = Application.get_env(:ticket_service, :qr_hmac_secret)
    :crypto.mac(:hmac, :sha256, secret, data) |> Base.url_encode64(padding: false)
  end

  defp hash_payload(payload) do
    :crypto.hash(:sha256, payload) |> Base.url_encode64(padding: false)
  end
end
