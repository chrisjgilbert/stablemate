require "test_helper"

# Pause/resume (scenario 19).
class Monitoring::Monitor::PausingTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  test "pause! sets status to paused" do
    monitor = monitors(:up)
    monitor.pause!
    assert monitor.paused?
  end

  # Scenario 19 — resume returns to pending if never pinged.
  test "resume! returns a never-pinged monitor to pending" do
    monitor = monitors(:pending)
    monitor.pause!
    monitor.resume!
    assert monitor.pending?
  end

  # Scenario 19 — resume re-evaluates a pinged monitor: still within grace -> up.
  test "resume! returns a recently-pinged monitor to up" do
    monitor = monitors(:up)
    monitor.pause!
    monitor.resume!
    assert monitor.up?
  end

  # Scenario 19 — resume re-evaluates: past grace -> down, and (because resume
  # routes through flag_missed!) opens an incident and sends one down alert so the
  # outage is never incident-less / alert-less.
  test "resume! marks an overdue monitor down, opening an incident and alerting once" do
    monitor = monitors(:up)
    monitor.pause!
    travel_to monitor.due_with_grace_at + 1.minute do
      assert_difference -> { monitor.incidents.open.count }, 1 do
        assert_enqueued_emails 1 do
          monitor.resume!
        end
      end
      assert monitor.down?
    end
  end
end
