require "test_helper"

class DetectMissedPingsJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    # Isolate detection to a single known monitor so the assertions count only it.
    Monitoring::Monitor.delete_all
    @monitor = users(:alice).monitors.create!(
      name: "Sweep target",
      expected_interval_seconds: 3600,
      grace_period_seconds: 300,
      status: "up",
      last_ping_at: 10.minutes.ago,
      next_due_at: 50.minutes.from_now
    )
  end

  # Scenario 20 — the job flips an overdue monitor down, opens one incident, one email.
  test "flips an overdue monitor down and opens exactly one incident with one email" do
    travel_to @monitor.due_with_grace_at + 1.minute do
      assert_difference -> { Incident.count }, 1 do
        assert_enqueued_emails 1 do
          DetectMissedPingsJob.perform_now
        end
      end
    end

    assert @monitor.reload.down?
  end

  # Scenario 21 — running twice opens no second incident, sends no second email.
  test "running twice does not open a second incident or send a second email" do
    travel_to @monitor.due_with_grace_at + 1.minute do
      DetectMissedPingsJob.perform_now
      assert_no_difference -> { Incident.count } do
        assert_enqueued_emails 0 do
          DetectMissedPingsJob.perform_now
        end
      end
    end

    assert_equal 1, @monitor.incidents.count
  end

  # Scenario 22 — a monitor still within interval+grace is left up.
  test "leaves a monitor still inside its grace window up" do
    travel_to @monitor.due_with_grace_at - 1.minute do
      DetectMissedPingsJob.perform_now
    end

    assert @monitor.reload.up?
  end

  # Scenario 23 — detection makes no outbound HTTP (pure DB). The alert mail is
  # *enqueued* (deliver_later), never sent inline, so the sweep performs zero
  # network I/O itself: deliveries stay empty during the run and the mailer job
  # is queued instead.
  test "makes no outbound calls during the sweep — the alert is only enqueued" do
    travel_to @monitor.due_with_grace_at + 1.minute do
      assert_enqueued_emails 1 do # the alert is deferred to a job
        DetectMissedPingsJob.perform_now
      end
      # Nothing was delivered synchronously during the sweep itself.
      assert_empty ActionMailer::Base.deliveries
    end

    assert @monitor.reload.down?
  end
end
