defmodule TicketServiceWeb.CaptchaController do
  use TicketServiceWeb, :controller

  alias TicketService.AntiBot.Detector

  @doc "Verify a CAPTCHA response and clear the session's bot flag."
  def verify(conn, %{"session_id" => session_id, "captcha_token" => token}) do
    case Detector.verify_captcha(session_id, token) do
      :ok ->
        json(conn, %{data: %{status: "verified"}})

      {:error, :session_not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Session not found"})
    end
  end

  def verify(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "session_id and captcha_token required"})
  end
end
