require "test_helper"

# The flag_missed! operation (scenarios 20, 21).
class Monitoring::Monitor::MissedPingTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  # flag_missed! is only ever called on a monitor the `overdue` scope selected, so
  # the unit precondition is an actually-overdue monitor (next_due_at + grace past).
  setup do
    @monitor = monitors(:up)
    @monitor.update!(next_due_at: 10.minutes.ago)
  end

  # Scenario 20 — up -> down, opens exactly one incident, enqueues one down email.
  test "flags an up monitor down, opens one incident, and enqueues one down email" do
    assert_difference -> { @monitor.incidents.count }, 1 do
      assert_enqueued_emails 1 do
        @monitor.flag_missed!
      end
    end

    assert @monitor.reload.down?
    incident = @monitor.incidents.open.sole
    assert_equal "missed_ping", incident.cause
    notification = @monitor.notifications.sole
    assert_equal "down", notification.event
    assert notification.delivered_at.present?
  end

  # Scenario 21 — running twice opens no second incident, sends no second email.
  test "flagging an already-down monitor opens no second incident or email" do
    @monitor.flag_missed!

    assert_no_difference -> { @monitor.incidents.count } do
      assert_enqueued_emails 0 do
        @monitor.flag_missed!
      end
    end

    assert_equal 1, @monitor.incidents.count
    assert_equal 1, @monitor.notifications.count
  end

  test "is a no-op for a non-up monitor" do
    @monitor.update!(status: "paused")
    assert_no_difference -> { Incident.count } do
      @monitor.flag_missed!
    end
    assert @monitor.reload.paused?
  end

  # WU-1 (H2) — a monitor pinged after the `overdue` query but before flag_missed!
  # runs must NOT be flagged down. The detection job holds a stale in-memory record;
  # flag_missed! re-reads fresh state under a lock and re-checks it's still overdue.
  test "does not flag a monitor that was pinged after the overdue query" do
    # The monitor was overdue when the sweep loaded it.
    @monitor.update!(status: "up", next_due_at: 10.minutes.ago)
    stale = Monitoring::Monitor.find(@monitor.id)
    assert stale.overdue_now?, "precondition: stale copy looks overdue"

    # A legitimate late ping then lands: still up, next_due_at in the future.
    @monitor.update!(last_ping_at: Time.current, next_due_at: 1.hour.from_now)

    assert_no_difference -> { Incident.count } do
      assert_enqueued_emails 0 do
        stale.flag_missed!
      end
    end

    assert stale.reload.up?, "must stay up, not be falsely flagged down"
  end
end
