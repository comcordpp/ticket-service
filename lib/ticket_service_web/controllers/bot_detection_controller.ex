defmodule TicketServiceWeb.BotDetectionController do
  use TicketServiceWeb, :controller

  alias TicketService.AntiBot.Detector

  @doc """
  GET /api/admin/bot-detection/stats

  Returns bot detection statistics: blocked count, flagged sessions, active rules.
  """
  def stats(conn, _params) do
    stats = Detector.get_stats()

    json(conn, %{
      data: %{
        total_analyzed: stats.total_analyzed,
        passed: stats.passed,
        captcha_challenged: stats.captcha_challenged,
        blocked: stats.blocked,
        captcha_verified: stats.captcha_verified,
        false_positives: stats.false_positives,
        active_sessions: stats.active_sessions,
        elevated_sessions: stats.elevated_sessions,
        high_risk_sessions: stats.high_risk_sessions,
        active_rules: stats.active_rules
      }
    })
  end

  @doc """
  GET /api/admin/bot-detection/audit-log

  Returns recent detection decisions for auditing and tuning.
  """
  def audit_log(conn, params) do
    limit = parse_int(params["limit"], 100)
    entries = Detector.get_audit_log(limit: limit)

    json(conn, %{data: entries})
  end

  @doc """
  GET /api/admin/bot-detection/rules

  Lists all active detection rules.
  """
  def index_rules(conn, _params) do
    rules = Detector.list_rules()

    json(conn, %{
      data:
        Enum.map(rules, fn rule ->
          %{
            id: rule.id,
            type: rule.type,
            value: rule.value,
            weight: rule.weight,
            description: rule.description,
            created_at: rule.created_at
          }
        end)
    })
  end

  @doc """
  POST /api/admin/bot-detection/rules

  Add or update a detection rule.

  Body:
    - type: "ip_watchlist" | "ua_pattern" | "fingerprint_block" | "high_risk_event"
    - value: the value to match (IP, regex pattern, fingerprint hash, event ID)
    - weight: score weight (default 40)
    - description: optional human-readable description
  """
  def create_rule(conn, params) do
    rule = %{
      type: parse_rule_type(params["type"]),
      value: params["value"],
      weight: parse_int(params["weight"], 40),
      description: params["description"] || ""
    }

    case validate_rule(rule) do
      :ok ->
        {:ok, created} = Detector.add_rule(rule)

        conn
        |> put_status(:created)
        |> json(%{
          data: %{
            id: created.id,
            type: created.type,
            value: created.value,
            weight: created.weight,
            description: created.description,
            created_at: created.created_at
          }
        })

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: reason})
    end
  end

  @doc """
  DELETE /api/admin/bot-detection/rules/:id

  Delete a detection rule.
  """
  def delete_rule(conn, %{"id" => rule_id}) do
    case Detector.delete_rule(rule_id) do
      :ok ->
        json(conn, %{data: %{status: "deleted"}})

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "Rule not found"})
    end
  end

  defp parse_rule_type("ip_watchlist"), do: :ip_watchlist
  defp parse_rule_type("ua_pattern"), do: :ua_pattern
  defp parse_rule_type("fingerprint_block"), do: :fingerprint_block
  defp parse_rule_type("high_risk_event"), do: :high_risk_event
  defp parse_rule_type(_), do: :ip_watchlist

  defp validate_rule(%{value: nil}), do: {:error, "value is required"}
  defp validate_rule(%{value: ""}), do: {:error, "value is required"}

  defp validate_rule(%{type: :ua_pattern, value: pattern}) do
    case Regex.compile(pattern) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, "invalid regex pattern"}
    end
  end

  defp validate_rule(_), do: :ok

  defp parse_int(nil, default), do: default
  defp parse_int(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {int, _} -> int
      :error -> default
    end
  end
  defp parse_int(val, _default) when is_integer(val), do: val
  defp parse_int(_, default), do: default
end
