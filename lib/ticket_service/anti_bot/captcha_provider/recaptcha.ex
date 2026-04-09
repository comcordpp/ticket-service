defmodule TicketService.AntiBot.CaptchaProvider.ReCaptcha do
  @moduledoc """
  Google reCAPTCHA verification provider.

  ## Configuration

      config :ticket_service, TicketService.AntiBot.CaptchaProvider,
        provider: TicketService.AntiBot.CaptchaProvider.ReCaptcha,
        site_key: "your-recaptcha-site-key",
        secret_key: "your-recaptcha-secret-key"
  """
  @behaviour TicketService.AntiBot.CaptchaProvider

  require Logger

  @verify_url "https://www.google.com/recaptcha/api/siteverify"

  @impl true
  def verify(token, remote_ip) do
    config = Application.get_env(:ticket_service, TicketService.AntiBot.CaptchaProvider, [])
    secret = Keyword.get(config, :secret_key, "")

    body =
      URI.encode_query(%{
        secret: secret,
        response: token,
        remoteip: remote_ip || ""
      })

    case :httpc.request(
           :post,
           {String.to_charlist(@verify_url), [], ~c"application/x-www-form-urlencoded",
            String.to_charlist(body)},
           [{:timeout, 5_000}],
           []
         ) do
      {:ok, {{_, 200, _}, _headers, resp_body}} ->
        case Jason.decode(to_string(resp_body)) do
          {:ok, %{"success" => true}} -> :ok
          {:ok, %{"success" => false}} -> {:error, :invalid_token}
          _ -> {:error, :provider_error, :invalid_response}
        end

      {:error, reason} ->
        Logger.error("reCAPTCHA verification failed: #{inspect(reason)}")
        {:error, :provider_error, reason}
    end
  end

  @impl true
  def site_key do
    config = Application.get_env(:ticket_service, TicketService.AntiBot.CaptchaProvider, [])
    Keyword.get(config, :site_key, "")
  end
end
