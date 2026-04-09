defmodule TicketService.Queue.FairQueueTest do
  use ExUnit.Case, async: false

  alias TicketService.Queue.FairQueue

  setup do
    event_id = "test-event-#{System.unique_integer([:positive])}"

    Application.put_env(:ticket_service, FairQueue,
      drain_rate: 3,
      pass_ttl_seconds: 2,
      batch_size: 2,
      drain_interval_ms: 100,
      max_queue_size: 5,
      measurement_window_ms: 500
    )

    start_supervised!({Registry, keys: :unique, name: TicketService.QueueRegistry})
    start_supervised!({DynamicSupervisor, name: TicketService.QueueSupervisor, strategy: :one_for_one})
    start_supervised!({Phoenix.PubSub, name: TicketService.PubSub})

    on_exit(fn -> Application.delete_env(:ticket_service, FairQueue) end)
    %{event_id: event_id}
  end

  describe "join/2" do
    test "grants immediate pass when queue is inactive", %{event_id: event_id} do
      assert :pass = FairQueue.join(event_id, "session-1")
    end

    test "auto-spawns queue process via DynamicSupervisor", %{event_id: event_id} do
      assert nil == GenServer.whereis(FairQueue.via(event_id))
      assert :pass = FairQueue.join(event_id, "session-1")
      assert is_pid(GenServer.whereis(FairQueue.via(event_id)))
    end

    test "returns :pass for session that already has a pass", %{event_id: event_id} do
      :pass = FairQueue.join(event_id, "session-1")
      assert :pass = FairQueue.join(event_id, "session-1")
    end
  end

  describe "check_position/2" do
    test "shows pass when granted", %{event_id: event_id} do
      :pass = FairQueue.join(event_id, "session-1")
      assert {:pass, %{expires_at: %DateTime{}}} = FairQueue.check_position(event_id, "session-1")
    end

    test "returns not_in_queue for unknown session", %{event_id: event_id} do
      FairQueue.ensure_started(event_id)
      assert {:not_in_queue, %{}} = FairQueue.check_position(event_id, "unknown")
    end

    test "returns not_in_queue when queue process doesn't exist", %{event_id: event_id} do
      assert {:not_in_queue, %{}} = FairQueue.check_position(event_id, "unknown")
    end
  end

  describe "validate_pass/2" do
    test "accepts valid pass", %{event_id: event_id} do
      :pass = FairQueue.join(event_id, "session-1")
      assert :ok = FairQueue.validate_pass(event_id, "session-1")
    end

    test "rejects unknown session", %{event_id: event_id} do
      FairQueue.ensure_started(event_id)
      assert {:error, :no_pass} = FairQueue.validate_pass(event_id, "unknown")
    end

    test "rejects expired pass", %{event_id: event_id} do
      :pass = FairQueue.join(event_id, "session-1")
      # pass_ttl is 2 seconds in test config
      Process.sleep(2_100)
      assert {:error, :pass_expired} = FairQueue.validate_pass(event_id, "session-1")
    end

    test "returns no_pass when queue process doesn't exist", %{event_id: event_id} do
      assert {:error, :no_pass} = FairQueue.validate_pass(event_id, "session-1")
    end
  end

  describe "release_pass/2" do
    test "clears the pass", %{event_id: event_id} do
      :pass = FairQueue.join(event_id, "session-1")
      FairQueue.release_pass(event_id, "session-1")
      Process.sleep(50)
      assert {:error, :no_pass} = FairQueue.validate_pass(event_id, "session-1")
    end

    test "no-ops when queue process doesn't exist", %{event_id: event_id} do
      assert :ok = FairQueue.release_pass(event_id, "session-1")
    end
  end

  describe "stats/1" do
    test "returns queue statistics", %{event_id: event_id} do
      FairQueue.ensure_started(event_id)
      assert {:ok, stats} = FairQueue.stats(event_id)
      assert stats.event_id == event_id
      assert stats.queue_depth == 0
      assert stats.drain_rate == 3
      assert is_float(stats.avg_wait_seconds)
      assert is_integer(stats.total_admitted)
    end

    test "returns error when queue not started", %{event_id: event_id} do
      assert {:error, :queue_not_found} = FairQueue.stats(event_id)
    end
  end

  describe "backpressure" do
    test "rejects when queue is full", %{event_id: event_id} do
      # Start queue and force it active
      {:ok, pid} = FairQueue.ensure_started(event_id)
      :sys.replace_state(pid, fn state -> %{state | active: true} end)

      # Fill up to max_queue_size (5)
      for i <- 1..5 do
        result = FairQueue.join(event_id, "fill-#{i}")
        assert result in [{:queued, i}]
      end

      # Next should be rejected
      assert {:error, :queue_full} = FairQueue.join(event_id, "overflow")
    end
  end

  describe "periodic drain" do
    test "admits queued sessions via drain tick", %{event_id: event_id} do
      {:ok, pid} = FairQueue.ensure_started(event_id)
      # Force queue active
      :sys.replace_state(pid, fn state -> %{state | active: true} end)

      # Enqueue some sessions
      {:queued, 1} = FairQueue.join(event_id, "drain-1")
      {:queued, 2} = FairQueue.join(event_id, "drain-2")
      {:queued, 3} = FairQueue.join(event_id, "drain-3")

      # Wait for drain tick (100ms interval, batch_size 2)
      Process.sleep(200)

      # First 2 should have been admitted
      assert {:pass, _} = FairQueue.check_position(event_id, "drain-1")
      assert {:pass, _} = FairQueue.check_position(event_id, "drain-2")
    end
  end

  describe "backward compatibility" do
    test "request_access/2 delegates to join/2", %{event_id: event_id} do
      assert :pass = FairQueue.request_access(event_id, "session-1")
    end

    test "check_status/2 delegates to check_position/2", %{event_id: event_id} do
      :pass = FairQueue.join(event_id, "session-1")
      assert {:pass, %{expires_at: _}} = FairQueue.check_status(event_id, "session-1")
    end

    test "info/1 delegates to stats/1", %{event_id: event_id} do
      FairQueue.ensure_started(event_id)
      assert {:ok, stats} = FairQueue.info(event_id)
      assert stats.event_id == event_id
    end
  end

  describe "ETS crash recovery" do
    test "recovers queue state after process restart", %{event_id: event_id} do
      {:ok, pid} = FairQueue.ensure_started(event_id)
      # Force active and enqueue
      :sys.replace_state(pid, fn state -> %{state | active: true} end)
      {:queued, 1} = FairQueue.join(event_id, "recover-1")
      {:queued, 2} = FairQueue.join(event_id, "recover-2")

      # Kill the process
      Process.exit(pid, :kill)
      Process.sleep(50)

      # Restart
      {:ok, _new_pid} = FairQueue.ensure_started(event_id)

      # Verify state recovered — the sessions should still be in ETS
      assert {:ok, stats} = FairQueue.stats(event_id)
      assert stats.queue_depth == 2
    end
  end
end
