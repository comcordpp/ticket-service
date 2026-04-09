defmodule TicketService.AntiBot.CaptchaProvider do
  @moduledoc """
  Behaviour for CAPTCHA verification providers.

  Abstracts hCaptcha/reCAPTCHA behind a common interface so providers
  can be swapped via configuration.

  ## Configuration

      config :ticket_service, TicketService.AntiBot.CaptchaProvider,
        provider: TicketService.AntiBot.CaptchaProvider.HCaptcha,
        site_key: "your-site-key",
        secret_key: "your-secret-key"
  """

  @type verify_result :: :ok | {:error, :invalid_token} | {:error, :provider_error, term()}

  @callback verify(token :: String.t(), remote_ip :: String.t() | nil) :: verify_result()
  @callback site_key() :: String.t()

  @doc "Verify a CAPTCHA token using the configured provider."
  def verify(token, remote_ip \\ nil) do
    provider().verify(token, remote_ip)
  end

  @doc "Get the site key for the configured provider."
  def site_key do
    provider().site_key()
  end

  defp provider do
    config = Application.get_env(:ticket_service, __MODULE__, [])
    Keyword.get(config, :provider, TicketService.AntiBot.CaptchaProvider.Noop)
  end
end
