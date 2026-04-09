defmodule TicketServiceWeb.OccupancyController do
  use TicketServiceWeb, :controller

  alias TicketService.Occupancy

  require Logger

  def entry(conn, params) do
    with {:ok, venue_id} <- require_param(params, "venue_id") do
      section_id = Map.get(params, "section_id", "default")
      gate_id = Map.get(params, "gate_id")
      count = Map.get(params, "count", 1)
      new_count = Occupancy.record_entry(venue_id, section_id, count)

      if gate_id do
        Logger.info("Occupancy entry: venue=#{venue_id} section=#{section_id} gate=#{gate_id} count=#{new_count}")
      end

      json(conn, %{
        data: %{
          venue_id: venue_id,
          section_id: section_id,
          count: new_count,
          venue_total: Occupancy.get_venue_total(venue_id),
          timestamp: DateTime.utc_now()
        }
      })
    else
      {:error, msg} ->
        conn |> put_status(:bad_request) |> json(%{error: msg})
    end
  end

  def exit_(conn, params) do
    with {:ok, venue_id} <- require_param(params, "venue_id") do
      section_id = Map.get(params, "section_id", "default")
      gate_id = Map.get(params, "gate_id")
      count = Map.get(params, "count", 1)
      current = Occupancy.get_section_count(venue_id, section_id)

      if current == 0 do
        Logger.warning("Exit without prior entry: venue=#{venue_id} section=#{section_id} gate=#{gate_id}")
      end

      new_count = Occupancy.record_exit(venue_id, section_id, count)

      json(conn, %{
        data: %{
          venue_id: venue_id,
          section_id: section_id,
          count: new_count,
          venue_total: Occupancy.get_venue_total(venue_id),
          timestamp: DateTime.utc_now()
        }
      })
    else
      {:error, msg} ->
        conn |> put_status(:bad_request) |> json(%{error: msg})
    end
  end

  def show(conn, %{"venue_id" => venue_id}) do
    total = Occupancy.get_venue_total(venue_id)
    capacity = Occupancy.get_venue_capacity(venue_id)

    data = %{
      venue_id: venue_id,
      total: total,
      timestamp: DateTime.utc_now()
    }

    data =
      case capacity do
        {:ok, cap} ->
          Map.merge(data, %{capacity: cap, utilization: Float.round(total / max(cap, 1) * 100, 1)})

        :not_set ->
          data
      end

    json(conn, %{data: data})
  end

  def sections(conn, %{"venue_id" => venue_id}) do
    breakdown = Occupancy.get_venue_breakdown(venue_id)
    total = Occupancy.get_venue_total(venue_id)

    json(conn, %{
      data: %{
        venue_id: venue_id,
        total: total,
        sections: Enum.map(breakdown, fn s ->
          %{section_id: s.section_id, count: s.count}
        end),
        timestamp: DateTime.utc_now()
      }
    })
  end

  defp require_param(params, key) do
    case Map.get(params, key) do
      nil -> {:error, "#{key} is required"}
      val -> {:ok, val}
    end
  end
end
