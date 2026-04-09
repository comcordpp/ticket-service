defmodule TicketServiceWeb.BotDetectionControllerTest do
  use TicketServiceWeb.ConnCase

  alias TicketService.AntiBot.Detector

  setup do
    start_supervised!(Detector)
    :ok
  end

  describe "GET /api/admin/bot-detection/stats" do
    test "returns detection statistics", %{conn: conn} do
      # Generate some traffic
      signals = %{user_agent: "Mozilla/5.0", fingerprint: "abc", js_executed: true}
      Detector.analyze("s1", signals)
      Detector.analyze("s2", signals)

      conn = get(conn, ~p"/api/admin/bot-detection/stats")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["total_analyzed"] == 2
      assert data["passed"] == 2
      assert is_integer(data["active_sessions"])
      assert is_integer(data["active_rules"])
    end
  end

  describe "GET /api/admin/bot-detection/audit-log" do
    test "returns recent audit log entries", %{conn: conn} do
      signals = %{user_agent: "Mozilla/5.0", fingerprint: "abc", js_executed: true}
      Detector.analyze("s-audit-ctrl", signals)

      conn = get(conn, ~p"/api/admin/bot-detection/audit-log")
      assert %{"data" => entries} = json_response(conn, 200)
      assert length(entries) >= 1
      entry = hd(entries)
      assert entry["session_id"] == "s-audit-ctrl"
      assert entry["decision"] == "pass"
    end

    test "respects limit parameter", %{conn: conn} do
      signals = %{user_agent: "Mozilla/5.0", fingerprint: "abc", js_executed: true}
      for i <- 1..5, do: Detector.analyze("s-limit-#{i}", signals)

      conn = get(conn, ~p"/api/admin/bot-detection/audit-log?limit=2")
      assert %{"data" => entries} = json_response(conn, 200)
      assert length(entries) == 2
    end
  end

  describe "POST /api/admin/bot-detection/rules" do
    test "creates an IP watchlist rule", %{conn: conn} do
      conn =
        post(conn, ~p"/api/admin/bot-detection/rules", %{
          "type" => "ip_watchlist",
          "value" => "10.0.0.1",
          "weight" => 40,
          "description" => "Suspicious IP"
        })

      assert %{"data" => rule} = json_response(conn, 201)
      assert rule["type"] == "ip_watchlist"
      assert rule["value"] == "10.0.0.1"
      assert rule["weight"] == 40
    end

    test "creates a UA pattern rule", %{conn: conn} do
      conn =
        post(conn, ~p"/api/admin/bot-detection/rules", %{
          "type" => "ua_pattern",
          "value" => "BadBot.*",
          "weight" => 50
        })

      assert %{"data" => rule} = json_response(conn, 201)
      assert rule["type"] == "ua_pattern"
    end

    test "rejects rule with missing value", %{conn: conn} do
      conn =
        post(conn, ~p"/api/admin/bot-detection/rules", %{
          "type" => "ip_watchlist",
          "value" => ""
        })

      assert %{"error" => _} = json_response(conn, 422)
    end

    test "rejects invalid regex pattern", %{conn: conn} do
      conn =
        post(conn, ~p"/api/admin/bot-detection/rules", %{
          "type" => "ua_pattern",
          "value" => "[invalid"
        })

      assert %{"error" => _} = json_response(conn, 422)
    end
  end

  describe "GET /api/admin/bot-detection/rules" do
    test "lists active rules", %{conn: conn} do
      Detector.add_rule(%{type: :ip_watchlist, value: "10.0.0.1"})
      Detector.add_rule(%{type: :ua_pattern, value: "Bot.*"})

      conn = get(conn, ~p"/api/admin/bot-detection/rules")
      assert %{"data" => rules} = json_response(conn, 200)
      assert length(rules) == 2
    end
  end

  describe "DELETE /api/admin/bot-detection/rules/:id" do
    test "deletes an existing rule", %{conn: conn} do
      {:ok, rule} = Detector.add_rule(%{type: :ip_watchlist, value: "10.0.0.1"})

      conn = delete(conn, ~p"/api/admin/bot-detection/rules/#{rule.id}")
      assert %{"data" => %{"status" => "deleted"}} = json_response(conn, 200)
    end

    test "returns 404 for nonexistent rule", %{conn: conn} do
      conn = delete(conn, ~p"/api/admin/bot-detection/rules/nonexistent")
      assert json_response(conn, 404)
    end
  end
end
