defmodule TicketService.AntiBot.CaptchaProvider.Noop do
  @moduledoc """
  No-op CAPTCHA provider for development and testing.
  Accepts any non-empty token.
  """
  @behaviour TicketService.AntiBot.CaptchaProvider

  @impl true
  def verify("", _remote_ip), do: {:error, :invalid_token}
  def verify(nil, _remote_ip), do: {:error, :invalid_token}
  def verify(_token, _remote_ip), do: :ok

  @impl true
  def site_key, do: "test-site-key"
end
