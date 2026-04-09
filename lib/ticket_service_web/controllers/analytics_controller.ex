defmodule TicketServiceWeb.AnalyticsController do
  use TicketServiceWeb, :controller

  alias TicketService.Analytics

  @doc "Get analytics snapshot for an event."
  def snapshot(conn, %{"event_id" => event_id}) do
    snapshot = Analytics.get_snapshot(event_id)
    json(conn, %{data: snapshot})
  end

  @doc "Get time-series data for a specific metric."
  def timeseries(conn, %{"event_id" => event_id, "metric" => metric} = params) do
    minutes = String.to_integer(Map.get(params, "minutes", "60"))
    metric_atom = String.to_existing_atom(metric)
    series = Analytics.get_timeseries(event_id, metric_atom, minutes)
    json(conn, %{data: series})
  rescue
    ArgumentError ->
      conn |> put_status(:bad_request) |> json(%{error: "Invalid metric: #{metric}"})
  end

  @doc "Configure an alert threshold."
  def set_alert(conn, %{"event_id" => event_id, "metric" => metric, "threshold" => threshold}) do
    metric_atom = String.to_existing_atom(metric)
    Analytics.set_alert(event_id, metric_atom, threshold)
    json(conn, %{data: %{status: "ok"}})
  rescue
    ArgumentError ->
      conn |> put_status(:bad_request) |> json(%{error: "Invalid metric: #{metric}"})
  end
end
