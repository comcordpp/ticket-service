defmodule TicketService.AntiBot.DetectorTest do
  use ExUnit.Case, async: false

  alias TicketService.AntiBot.Detector

  setup do
    start_supervised!(Detector)
    :ok
  end

  test "normal request passes" do
    signals = %{user_agent: "Mozilla/5.0", fingerprint: "abc123"}
    assert {:ok, :pass} = Detector.analyze("session-normal", signals)
  end

  test "missing user-agent increases score" do
    signals = %{user_agent: nil, fingerprint: "abc123"}
    {:ok, result} = Detector.analyze("session-no-ua", signals)
    # Score should be 30 (missing UA) + 15 if no fingerprint
    # With fingerprint but no UA: 30
    score = Detector.get_score("session-no-ua")
    assert score >= 30
    # But not enough for captcha alone
    assert result == :pass
  end

  test "bot user-agent triggers captcha" do
    signals = %{user_agent: "Googlebot/2.1", fingerprint: nil}
    {:ok, result, score} = Detector.analyze("session-bot", signals)
    # Bot UA (50) + missing fingerprint (15) = 65 >= 60 threshold
    assert result == :captcha_required
    assert score >= 60
  end

  test "captcha verification lowers score" do
    signals = %{user_agent: "Scraperbot", fingerprint: nil}
    {:ok, :captcha_required, _} = Detector.analyze("session-captcha", signals)

    :ok = Detector.verify_captcha("session-captcha", "valid-token")

    signals2 = %{user_agent: "Scraperbot", fingerprint: "fp123"}
    {:ok, result} = Detector.analyze("session-captcha", signals2)
    assert result == :pass
  end

  test "get_score returns 0 for unknown session" do
    assert Detector.get_score("unknown") == 0
  end

  test "record_cart_action tracks velocity" do
    signals = %{user_agent: "Mozilla/5.0", fingerprint: "abc"}

    # Record many cart actions rapidly
    for _ <- 1..10, do: Detector.record_cart_action("session-velocity")
    Process.sleep(10)

    {:ok, _} = Detector.analyze("session-velocity", signals)
    score = Detector.get_score("session-velocity")
    # Should have elevated score from cart velocity
    assert score > 0
  end
end
