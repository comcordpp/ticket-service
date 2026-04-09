defmodule TicketServiceWeb.CaptchaController do
  use TicketServiceWeb, :controller

  alias TicketService.AntiBot.Detector

  @doc "Verify a CAPTCHA response and clear the session's bot flag."
  def verify(conn, %{"session_id" => session_id, "captcha_token" => token}) do
    remote_ip = client_ip(conn)

    case Detector.verify_captcha(session_id, token, remote_ip) do
      :ok ->
        json(conn, %{data: %{status: "verified"}})

      {:error, :session_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Session not found"})

      {:error, :invalid_token} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "Invalid CAPTCHA token"})

      {:error, :provider_error} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "CAPTCHA verification temporarily unavailable"})
    end
  end

  def verify(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "session_id and captcha_token required"})
  end

  defp client_ip(conn) do
    case Plug.Conn.get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] ->
        forwarded |> String.split(",") |> List.first() |> String.trim()

      [] ->
        conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
