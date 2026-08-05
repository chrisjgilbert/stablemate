require "test_helper"

class DetectMissedPingsJobTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  setup do
    # Isolate detection to a single known monitor so the assertions count only it.
    Monitoring::Monitor.delete_all
    @project = users(:alice).projects.sole
    @monitor = @project.monitors.create!(
      name: "Sweep target",
      expected_interval_seconds: 3600,
      grace_period_seconds: 300,
      status: "up",
      last_ping_at: 10.minutes.ago,
      next_due_at: 50.minutes.from_now
    )
  end

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

  test "leaves a monitor still inside its grace window up" do
    travel_to @monitor.due_with_grace_at - 1.minute do
      DetectMissedPingsJob.perform_now
    end

    assert @monitor.reload.up?
  end

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

  # Closing an account cascades away every one of its monitors at once
  # (User::Closure), so a row can vanish between the sweep's query and its turn.
  # flag_missed! re-reads under a lock, which raises RecordNotFound on a missing
  # row — and one raise aborts the whole run, leaving real outages unalerted
  # because someone else deleted their account in the same 30 seconds.
  #
  # The resilience itself is ApplicationJob#each_record, shared by every sweep
  # and tested in application_job_test.rb. What this pins is the WIRING: dropping
  # back to a bare `overdue.find_each` would still pass every other test here.
  #
  # The overdue scope is swapped with `Object#stub` (minitest-mock), which
  # restores it in an ensure — not the alias-on-the-real-singleton-class the
  # earlier version used, which was one skipped ensure away from breaking every
  # later test in the worker.
  test "sweeps through each_record, so a monitor deleted mid-sweep does not abort the run" do
    attrs = { expected_interval_seconds: 3600, grace_period_seconds: 300,
              status: "up", last_ping_at: 3.days.ago, next_due_at: 3.days.ago }
    ghost = @project.monitors.create!(name: "ghost", **attrs)
    survivor = @project.monitors.create!(name: "survivor", **attrs)

    # The batch as the job loaded it: a loaded relation iterates the records it
    # already holds, so it still yields the row deleted underneath it.
    batch = Monitoring::Monitor.where(id: [ ghost.id, survivor.id ]).load
    Monitoring::Monitor.where(id: ghost.id).delete_all

    Monitoring::Monitor.stub(:overdue, batch) do
      assert_nothing_raised { DetectMissedPingsJob.perform_now }
    end

    assert survivor.reload.down?, "the sweep must carry on past a deleted record"
  end
end
