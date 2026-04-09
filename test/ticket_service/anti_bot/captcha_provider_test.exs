defmodule TicketService.AntiBot.CaptchaProviderTest do
  use ExUnit.Case, async: true

  alias TicketService.AntiBot.CaptchaProvider

  describe "Noop provider" do
    setup do
      Application.put_env(:ticket_service, CaptchaProvider,
        provider: TicketService.AntiBot.CaptchaProvider.Noop
      )

      on_exit(fn -> Application.delete_env(:ticket_service, CaptchaProvider) end)
      :ok
    end

    test "accepts any non-empty token" do
      assert :ok = CaptchaProvider.verify("valid-token")
      assert :ok = CaptchaProvider.verify("any-string", "1.2.3.4")
    end

    test "rejects empty token" do
      assert {:error, :invalid_token} = CaptchaProvider.verify("")
    end

    test "rejects nil token" do
      assert {:error, :invalid_token} = CaptchaProvider.verify(nil)
    end

    test "returns test site key" do
      assert CaptchaProvider.site_key() == "test-site-key"
    end
  end

  describe "provider selection" do
    test "defaults to Noop provider when not configured" do
      Application.delete_env(:ticket_service, CaptchaProvider)
      assert :ok = CaptchaProvider.verify("token")
    end
  end
end
