defmodule TicketService.AntiBot.DetectorTest do
  use ExUnit.Case, async: false

  alias TicketService.AntiBot.Detector

  setup do
    # Clean ETS tables if they exist from a previous test
    try do
      :ets.delete_all_objects(:bot_fingerprints)
    rescue
      ArgumentError -> :ok
    end

    try do
      :ets.delete_all_objects(:bot_audit_log)
    rescue
      ArgumentError -> :ok
    end

    start_supervised!(Detector)
    :ok
  end

  describe "analyze/2" do
    test "normal request with all signals passes" do
      signals = %{
        user_agent: "Mozilla/5.0",
        fingerprint: "abc123",
        accept_language: "en-US",
        screen_resolution: "1920x1080",
        js_executed: true,
        ip: "1.2.3.4"
      }

      assert {:ok, :pass} = Detector.analyze("session-normal", signals)
    end

    test "missing user-agent increases score" do
      signals = %{user_agent: nil, fingerprint: "abc123", js_executed: true}
      {:ok, _result} = Detector.analyze("session-no-ua", signals)
      score = Detector.get_score("session-no-ua")
      assert score >= 30
    end

    test "bot user-agent triggers captcha" do
      signals = %{user_agent: "Googlebot/2.1", fingerprint: nil, js_executed: false}
      {:ok, result, score} = Detector.analyze("session-bot", signals)
      # Bot UA (50) + missing fingerprint (15) + missing JS (15) = 80 >= 60 threshold
      assert result == :captcha_required
      assert score >= 60
    end

    test "missing JS execution marker adds score" do
      signals = %{user_agent: "Mozilla/5.0", fingerprint: "abc123", js_executed: false}
      {:ok, _} = Detector.analyze("session-no-js", signals)
      score = Detector.get_score("session-no-js")
      assert score >= 15
    end

    test "present JS execution marker does not add score" do
      signals = %{user_agent: "Mozilla/5.0", fingerprint: "abc123", js_executed: true}
      {:ok, :pass} = Detector.analyze("session-with-js", signals)
      score = Detector.get_score("session-with-js")
      assert score == 0
    end

    test "duplicate fingerprint across sessions increases score" do
      signals = %{
        user_agent: "Mozilla/5.0",
        fingerprint: "shared-fp-123",
        js_executed: true
      }

      # First session with this fingerprint
      {:ok, :pass} = Detector.analyze("session-A", signals)
      score_a = Detector.get_score("session-A")

      # Second session with same fingerprint - should get duplicate penalty
      {:ok, _} = Detector.analyze("session-B", signals)
      score_b = Detector.get_score("session-B")

      assert score_b > score_a
      assert score_b >= 20
    end

    test "computes fingerprint from UA + accept-language + screen resolution" do
      signals1 = %{
        user_agent: "Mozilla/5.0",
        accept_language: "en-US",
        screen_resolution: "1920x1080",
        js_executed: true
      }

      signals2 = %{
        user_agent: "Mozilla/5.0",
        accept_language: "en-US",
        screen_resolution: "1920x1080",
        js_executed: true
      }

      # Same composite signals = same fingerprint = duplicate detection on second session
      {:ok, :pass} = Detector.analyze("session-fp-1", signals1)
      {:ok, _} = Detector.analyze("session-fp-2", signals2)
      score = Detector.get_score("session-fp-2")
      # Should have duplicate fingerprint penalty
      assert score >= 20
    end

    test "very high score blocks request" do
      # Configure low block threshold for testing
      Application.put_env(:ticket_service, Detector, captcha_threshold: 30, block_threshold: 50)

      signals = %{user_agent: "Scraperbot/1.0", fingerprint: nil, js_executed: false}
      # Bot UA (50) + missing fingerprint (15) + missing JS (15) = 80 >= 50
      {:ok, :blocked, score} = Detector.analyze("session-blocked", signals)
      assert score >= 50

      Application.delete_env(:ticket_service, Detector)
    end
  end

  describe "verify_captcha/3" do
    test "verification lowers score and marks captcha verified" do
      signals = %{user_agent: "Scraperbot", fingerprint: nil, js_executed: false}
      {:ok, :captcha_required, _} = Detector.analyze("session-captcha", signals)

      :ok = Detector.verify_captcha("session-captcha", "valid-token")

      # Re-analyze with better signals should pass now
      signals2 = %{user_agent: "Scraperbot", fingerprint: "fp123", js_executed: true}
      {:ok, result} = Detector.analyze("session-captcha", signals2)
      assert result == :pass
    end

    test "returns error for unknown session" do
      assert {:error, :session_not_found} = Detector.verify_captcha("unknown", "token")
    end
  end

  describe "get_score/1" do
    test "returns 0 for unknown session" do
      assert Detector.get_score("unknown") == 0
    end
  end

  describe "record_cart_action/1" do
    test "tracks cart velocity and increases score" do
      signals = %{user_agent: "Mozilla/5.0", fingerprint: "abc", js_executed: true}

      # Record many cart actions rapidly
      for _ <- 1..10, do: Detector.record_cart_action("session-velocity")
      Process.sleep(10)

      {:ok, _} = Detector.analyze("session-velocity", signals)
      score = Detector.get_score("session-velocity")
      assert score > 0
    end
  end

  describe "rules" do
    test "add and list rules" do
      {:ok, rule} =
        Detector.add_rule(%{type: :ip_watchlist, value: "10.0.0.1", weight: 40, description: "Test IP"})

      assert rule.type == :ip_watchlist
      assert rule.value == "10.0.0.1"

      rules = Detector.list_rules()
      assert length(rules) == 1
      assert hd(rules).id == rule.id
    end

    test "IP watchlist rule increases score" do
      {:ok, _} =
        Detector.add_rule(%{type: :ip_watchlist, value: "10.0.0.99", weight: 40})

      signals = %{
        user_agent: "Mozilla/5.0",
        fingerprint: "abc",
        js_executed: true,
        ip: "10.0.0.99"
      }

      {:ok, _} = Detector.analyze("session-ip-rule", signals)
      score = Detector.get_score("session-ip-rule")
      assert score >= 40
    end

    test "UA pattern rule increases score" do
      {:ok, _} =
        Detector.add_rule(%{type: :ua_pattern, value: "EvilScraper", weight: 50})

      signals = %{
        user_agent: "EvilScraper/1.0",
        fingerprint: "abc",
        js_executed: true,
        ip: "1.2.3.4"
      }

      {:ok, _} = Detector.analyze("session-ua-rule", signals)
      score = Detector.get_score("session-ua-rule")
      assert score >= 50
    end

    test "high risk event rule increases score" do
      {:ok, _} =
        Detector.add_rule(%{type: :high_risk_event, value: "event-123", weight: 10})

      signals = %{
        user_agent: "Mozilla/5.0",
        fingerprint: "abc",
        js_executed: true,
        event_id: "event-123"
      }

      {:ok, _} = Detector.analyze("session-event-rule", signals)
      score = Detector.get_score("session-event-rule")
      assert score >= 10
    end

    test "delete rule" do
      {:ok, rule} = Detector.add_rule(%{type: :ip_watchlist, value: "1.1.1.1"})
      assert :ok = Detector.delete_rule(rule.id)
      assert {:error, :not_found} = Detector.delete_rule(rule.id)
      assert Detector.list_rules() == []
    end
  end

  describe "get_stats/0" do
    test "tracks detection statistics" do
      signals_good = %{user_agent: "Mozilla/5.0", fingerprint: "abc", js_executed: true}
      signals_bad = %{user_agent: "Scraperbot", fingerprint: nil, js_executed: false}

      {:ok, :pass} = Detector.analyze("s1", signals_good)
      {:ok, :pass} = Detector.analyze("s2", signals_good)
      {:ok, :captcha_required, _} = Detector.analyze("s3", signals_bad)

      stats = Detector.get_stats()
      assert stats.total_analyzed == 3
      assert stats.passed == 2
      assert stats.captcha_challenged == 1
      assert stats.active_sessions == 3
    end
  end

  describe "get_audit_log/1" do
    test "records detection decisions" do
      signals = %{user_agent: "Mozilla/5.0", fingerprint: "abc", js_executed: true}
      {:ok, :pass} = Detector.analyze("s-audit", signals)

      log = Detector.get_audit_log(limit: 10)
      assert length(log) >= 1

      entry = hd(log)
      assert entry.session_id == "s-audit"
      assert entry.decision == :pass
      assert entry.score == 0
    end
  end

  describe "configurable velocity threshold" do
    test "uses configured velocity threshold" do
      Application.put_env(:ticket_service, Detector, velocity_threshold_ms: 1000)

      signals = %{user_agent: "Mozilla/5.0", fingerprint: "abc", js_executed: true}

      # Two rapid requests
      {:ok, :pass} = Detector.analyze("session-vel", signals)
      {:ok, _} = Detector.analyze("session-vel", signals)
      score = Detector.get_score("session-vel")
      # Should detect sub-1000ms timing as suspicious
      assert score >= 10

      Application.delete_env(:ticket_service, Detector)
    end
  end
end
