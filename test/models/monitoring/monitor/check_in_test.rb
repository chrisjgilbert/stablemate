require "test_helper"

# Unit test for the Monitoring::Monitor::CheckIn operation, reached via
# monitor.check_in!.
class Monitoring::Monitor::CheckInTest < ActiveSupport::TestCase
  setup { @monitor = monitors(:pending) }

  test "records a success PingEvent" do
    assert_difference -> { @monitor.ping_events.count }, 1 do
      @monitor.check_in!(received_at: Time.current)
    end

    event = @monitor.ping_events.order(:received_at).last
    assert_equal "success", event.kind
    # Rails' default timestamping still fills created_at (no manual plumbing).
    assert event.created_at.present?
  end

  test "moves last_ping_at and next_due_at by the expected interval" do
    freeze_time do
      now = Time.current
      @monitor.check_in!(received_at: now)

      assert_equal now, @monitor.last_ping_at
      assert_equal now + @monitor.expected_interval_seconds.seconds, @monitor.next_due_at
    end
  end

  test "transitions a pending monitor to up" do
    assert_equal "pending", @monitor.status
    @monitor.check_in!(received_at: Time.current)
    assert_equal "up", @monitor.status
  end

  test "leaves an up monitor up (timestamps only, no Phase 1 transitions)" do
    up = monitors(:up)
    up.check_in!(received_at: Time.current)
    assert_equal "up", up.status
  end

  test "captures source_ip and duration_ms when given" do
    @monitor.check_in!(received_at: Time.current, source_ip: "203.0.113.7", duration_ms: 1234)

    event = @monitor.ping_events.order(:received_at).last
    assert_equal "203.0.113.7", event.source_ip
    assert_equal 1234, event.duration_ms
  end

  test "persists the moved timestamps to the database" do
    freeze_time do
      @monitor.check_in!(received_at: Time.current)
      @monitor.reload
      assert_equal Time.current, @monitor.last_ping_at
    end
  end
end
