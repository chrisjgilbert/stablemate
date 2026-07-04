require "test_helper"

# Plan-downgrade suspend/reactivate (issue #19).
class Monitoring::Monitor::SuspensionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  test "suspend! sets status to suspended" do
    monitor = monitors(:up)
    monitor.suspend!
    assert monitor.suspended?
  end

  test "suspend! is idempotent" do
    monitor = monitors(:up)
    monitor.suspend!
    monitor.suspend!
    assert monitor.suspended?
  end

  test "reactivate! returns a never-pinged monitor to pending" do
    monitor = monitors(:pending)
    monitor.suspend!
    monitor.reactivate!
    assert monitor.pending?
  end

  test "reactivate! returns a recently-pinged monitor to up" do
    monitor = monitors(:up)
    monitor.suspend!
    monitor.reactivate!
    assert monitor.up?
  end

  test "reactivate! marks an overdue monitor down, opening an incident and alerting once" do
    monitor = monitors(:up)
    monitor.suspend!
    travel_to monitor.due_with_grace_at + 1.minute do
      assert_difference -> { monitor.incidents.open.count }, 1 do
        assert_enqueued_emails 1 do
          monitor.reactivate!
        end
      end
      assert monitor.down?
    end
  end

  # WU-2 (H1) — suspending a down monitor resolves its incident, so the plan
  # downgrade never leaves a stranded outage accruing phantom downtime.
  test "suspend! resolves the open incident of a down monitor" do
    monitor = monitors(:up)
    monitor.update!(next_due_at: 10.minutes.ago)
    monitor.flag_missed!
    assert monitor.incidents.open.exists?

    monitor.suspend!

    assert monitor.suspended?
    refute monitor.incidents.open.exists?
  end

  test "a suspended monitor is excluded from the detectable/overdue scopes" do
    monitor = monitors(:up)
    monitor.update!(next_due_at: 2.hours.ago)
    assert_includes Monitoring::Monitor.overdue, monitor

    monitor.suspend!
    refute_includes Monitoring::Monitor.detectable, monitor
    refute_includes Monitoring::Monitor.overdue, monitor
  end
end
