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

  # F11 — suspend! had pause!'s bug: the open-incident SELECT ran unlocked, so a
  # detection sweep landing between that read and the status flip left the monitor
  # `suspended` WITH an open incident (and a down email for a monitor the plan
  # downgrade had just stopped monitoring). See the twin test in PausingTest for
  # why this pins the lock ordering rather than driving two real connections.
  test "suspend! takes the row lock before reading the open incident" do
    monitor = monitors(:up)
    monitor.update!(next_due_at: 10.minutes.ago)
    monitor.flag_missed!

    statements = sql_executed_during { monitor.suspend! }
    locked_at  = statements.index { |sql| sql.match?(/FROM "monitors".*FOR UPDATE/m) }
    read_at    = statements.index { |sql| sql.match?(/FROM "incidents".*resolved_at/m) }

    assert locked_at, "suspend! must lock the monitor row"
    assert read_at, "suspend! must read the open incident"
    assert locked_at < read_at,
      "suspend! must hold the row lock before reading the incident, or a racing sweep " \
      "can open one between the read and the flip"
  end

  # The other ordering: the sweep committed first, so the in-memory monitor is
  # stale. Reloading under the lock is what lets suspend! see the incident.
  test "suspend! resolves an incident opened after the monitor was loaded" do
    monitor = monitors(:up)
    Monitoring::Monitor.find(monitor.id).then do |sweep_copy|
      sweep_copy.update!(next_due_at: 10.minutes.ago)
      sweep_copy.flag_missed!
    end
    assert monitor.up?, "the in-memory copy is deliberately stale"

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

  private
    # The SQL a block issues, in order — used to pin lock-before-read ordering.
    def sql_executed_during
      statements = []
      collect = ->(*, payload) { statements << payload[:sql] }
      ActiveSupport::Notifications.subscribed(collect, "sql.active_record") { yield }
      statements
    end
end
