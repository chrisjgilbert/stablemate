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

  # Closing an account cascades away every one of its monitors at once
  # (User::Closure), so a row can vanish between the sweep's query and its turn.
  # flag_missed! re-reads under a lock, which raises RecordNotFound on a missing
  # row — and one raise used to abort the whole run, leaving real outages
  # unalerted because someone else deleted their account in the same 30 seconds.
  test "a monitor deleted mid-sweep does not abort the run" do
    attrs = { expected_interval_seconds: 3600, grace_period_seconds: 300,
              status: "up", last_ping_at: 3.days.ago, next_due_at: 3.days.ago }
    ghost = @monitor.project.monitors.create!(name: "ghost", **attrs)
    survivor = @monitor.project.monitors.create!(name: "survivor", **attrs)
    Monitoring::Monitor.where(id: ghost.id).delete_all

    # A scope that still yields the vanished record, as the real batch would.
    fake = Struct.new(:records) { def find_each(&block) = records.each(&block) }
                 .new([ ghost, survivor ])
    klass = Monitoring::Monitor.singleton_class
    klass.send(:alias_method, :real_overdue, :overdue)
    klass.send(:define_method, :overdue) { fake }

    begin
      assert_nothing_raised { DetectMissedPingsJob.perform_now }
      assert survivor.reload.down?, "the sweep must carry on past a deleted record"
    ensure
      klass.send(:alias_method, :overdue, :real_overdue)
      klass.send(:remove_method, :real_overdue)
    end
  end
end
