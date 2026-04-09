defmodule TicketService.Analytics do
  @moduledoc """
  DA-2: Real-Time Analytics engine.

  Tracks time-series metrics: tickets sold per minute, active queue size,
  cart conversion rate, and alerts when thresholds are exceeded.

  Uses ETS for fast in-memory metric storage with periodic aggregation.
  """
  use GenServer

  require Logger

  @metrics_window_minutes 60
  @aggregation_interval_ms 10_000

  defstruct [
    :ets_table,
    alerts: []
  ]

  # --- Client API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Record a ticket sale event."
  def record_sale(event_id, quantity \\ 1) do
    record_metric(event_id, :sales, quantity)
  end

  @doc "Record a cart creation event."
  def record_cart_created(event_id) do
    record_metric(event_id, :carts_created, 1)
  end

  @doc "Record a checkout completion."
  def record_checkout(event_id) do
    record_metric(event_id, :checkouts, 1)
  end

  @doc "Record queue entry."
  def record_queue_join(event_id) do
    record_metric(event_id, :queue_joins, 1)
  end

  @doc """
  Get analytics snapshot for an event.

  Returns tickets/minute, cart conversion rate, queue metrics, and active alerts.
  """
  def get_snapshot(event_id) do
    GenServer.call(__MODULE__, {:get_snapshot, event_id})
  end

  @doc "Get time-series data for charts."
  def get_timeseries(event_id, metric, minutes \\ 60) do
    GenServer.call(__MODULE__, {:get_timeseries, event_id, metric, minutes})
  end

  @doc "Configure alert thresholds."
  def set_alert(event_id, metric, threshold) do
    GenServer.cast(__MODULE__, {:set_alert, event_id, metric, threshold})
  end

  # --- Server Callbacks ---

  @impl true
  def init(_opts) do
    table = :ets.new(:analytics, [:set, :public, :named_table, read_concurrency: true])
    Process.send_after(self(), :aggregate, @aggregation_interval_ms)
    {:ok, %__MODULE__{ets_table: table}}
  end

  @impl true
  def handle_call({:get_snapshot, event_id}, _from, state) do
    now_minute = current_minute()

    sales_per_min = get_metric_for_minute(event_id, :sales, now_minute)
    carts = get_metric_sum(event_id, :carts_created, 60)
    checkouts = get_metric_sum(event_id, :checkouts, 60)
    queue_joins = get_metric_sum(event_id, :queue_joins, 60)

    conversion_rate =
      if carts > 0 do
        Float.round(checkouts / carts * 100, 1)
      else
        0.0
      end

    snapshot = %{
      event_id: event_id,
      sales_per_minute: sales_per_min,
      total_sales_last_hour: get_metric_sum(event_id, :sales, 60),
      cart_conversion_rate: conversion_rate,
      carts_created_last_hour: carts,
      checkouts_last_hour: checkouts,
      queue_joins_last_hour: queue_joins,
      alerts: Enum.filter(state.alerts, fn a -> a.event_id == event_id end),
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_call({:get_timeseries, event_id, metric, minutes}, _from, state) do
    now_minute = current_minute()

    series =
      for offset <- (minutes - 1)..0 do
        minute = now_minute - offset
        value = get_metric_for_minute(event_id, metric, minute)
        %{minute: minute, value: value}
      end

    {:reply, series, state}
  end

  @impl true
  def handle_cast({:set_alert, event_id, metric, threshold}, state) do
    alert = %{event_id: event_id, metric: metric, threshold: threshold, triggered: false}
    alerts = [alert | Enum.reject(state.alerts, fn a -> a.event_id == event_id and a.metric == metric end)]
    {:noreply, %{state | alerts: alerts}}
  end

  @impl true
  def handle_info(:aggregate, state) do
    # Check alert thresholds
    state = check_alerts(state)

    # Clean up old data (beyond window)
    cleanup_old_data()

    Process.send_after(self(), :aggregate, @aggregation_interval_ms)
    {:noreply, state}
  end

  # --- Private ---

  defp record_metric(event_id, metric, value) do
    minute = current_minute()
    key = {event_id, metric, minute}

    :ets.update_counter(:analytics, key, {2, value}, {key, 0})
  end

  defp get_metric_for_minute(event_id, metric, minute) do
    key = {event_id, metric, minute}

    case :ets.lookup(:analytics, key) do
      [{_, count}] -> count
      [] -> 0
    end
  end

  defp get_metric_sum(event_id, metric, minutes) do
    now_minute = current_minute()

    Enum.reduce((minutes - 1)..0, 0, fn offset, acc ->
      acc + get_metric_for_minute(event_id, metric, now_minute - offset)
    end)
  end

  defp current_minute do
    DateTime.utc_now() |> DateTime.to_unix() |> div(60)
  end

  defp cleanup_old_data do
    cutoff = current_minute() - @metrics_window_minutes - 5

    :ets.foldl(
      fn {{_eid, _metric, minute} = key, _val}, _acc ->
        if minute < cutoff, do: :ets.delete(:analytics, key)
      end,
      nil,
      :analytics
    )
  rescue
    _ -> :ok
  end

  defp check_alerts(state) do
    now_minute = current_minute()

    alerts =
      Enum.map(state.alerts, fn alert ->
        current = get_metric_for_minute(alert.event_id, alert.metric, now_minute)

        if current >= alert.threshold and not alert.triggered do
          Logger.warning("Alert: #{alert.metric} for event #{alert.event_id} = #{current} (threshold: #{alert.threshold})")

          TicketServiceWeb.Endpoint.broadcast(
            "dashboard:#{alert.event_id}",
            "dashboard:alert",
            %{metric: alert.metric, value: current, threshold: alert.threshold}
          )

          %{alert | triggered: true}
        else
          if current < alert.threshold do
            %{alert | triggered: false}
          else
            alert
          end
        end
      end)

    %{state | alerts: alerts}
  end
end
