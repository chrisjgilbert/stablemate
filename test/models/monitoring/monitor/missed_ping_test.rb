require "test_helper"

# The flag_missed! operation (scenarios 20, 21).
class Monitoring::Monitor::MissedPingTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup { @monitor = monitors(:up) }

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
end
