defmodule TicketService.Queue.FairQueueTest do
  use ExUnit.Case, async: false

  alias TicketService.Queue.FairQueue

  @event_id "test-event-#{System.unique_integer([:positive])}"

  setup do
    # Start a queue for the test event with low thresholds
    Application.put_env(:ticket_service, FairQueue,
      activation_threshold: 3,
      pass_ttl_seconds: 5,
      batch_size: 2,
      measurement_window_ms: 1_000
    )

    start_supervised!({Registry, keys: :unique, name: TicketService.QueueRegistry})
    start_supervised!({FairQueue, event_id: @event_id})

    on_exit(fn -> Application.delete_env(:ticket_service, FairQueue) end)
    :ok
  end

  test "grants immediate pass when queue is inactive" do
    assert :pass = FairQueue.request_access(@event_id, "session-1")
  end

  test "check_status shows pass when granted" do
    :pass = FairQueue.request_access(@event_id, "session-1")
    assert {:pass, %{expires_at: _}} = FairQueue.check_status(@event_id, "session-1")
  end

  test "validate_pass accepts valid pass" do
    :pass = FairQueue.request_access(@event_id, "session-1")
    assert :ok = FairQueue.validate_pass(@event_id, "session-1")
  end

  test "validate_pass rejects unknown session" do
    assert {:error, :no_pass} = FairQueue.validate_pass(@event_id, "unknown")
  end

  test "release_pass clears the pass" do
    :pass = FairQueue.request_access(@event_id, "session-1")
    FairQueue.release_pass(@event_id, "session-1")
    # Small delay for async cast
    Process.sleep(50)
    assert {:error, :no_pass} = FairQueue.validate_pass(@event_id, "session-1")
  end

  test "info returns queue statistics" do
    info = FairQueue.info(@event_id)
    assert info.event_id == @event_id
    assert info.queue_size == 0
    assert is_boolean(info.active)
  end
end
