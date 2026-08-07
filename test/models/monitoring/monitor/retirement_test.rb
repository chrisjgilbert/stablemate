require "test_helper"

# `retired` is the prune state (v1-scope §6.1): the task left the config, so the
# monitor leaves the monitored world — history kept, no cap slot, revived by the
# sync when the task comes back. Retire, never delete.
class Monitoring::Monitor::RetirementTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  setup do
    @project = users(:carol).projects.sole
    @monitor = @project.monitors.create!(
      name: "daily_digest", registration_key: "daily_digest", source: "gem", status: "up",
      expected_interval_seconds: 3600, grace_period_seconds: 300,
      last_ping_at: 10.minutes.ago, next_due_at: 50.minutes.from_now
    )
  end

  # --- Retiring ---------------------------------------------------------------

  test "retiring leaves the monitored world and remembers what it retired from" do
    @monitor.retire!

    assert_equal "retired", @monitor.reload.status
    assert_equal "up", @monitor.status_before_retirement
    assert_not @monitor.monitored?
  end

  test "retiring is idempotent and cannot overwrite its own memory" do
    @monitor.retire!
    @monitor.retire!

    assert_equal "retired", @monitor.reload.status
    assert_equal "up", @monitor.status_before_retirement
  end

  # A stranded open incident on a not-monitored monitor corrupts the rollup: the
  # outage day would score 100% up. Exactly what pause! and suspend! both do, for
  # the same reason.
  test "retiring a down monitor resolves its incident without an alert" do
    outage_started = 2.hours.ago
    @monitor.update!(status: "down")
    incident = @monitor.incidents.create!(started_at: outage_started)

    assert_no_difference -> { Notification.count } do
      assert_no_emails { @monitor.retire! }
    end

    assert_not_nil incident.reload.resolved_at
    assert_equal "down", @monitor.reload.status_before_retirement
  end

  test "the retired day keeps the downtime the monitor really had" do
    started = Time.current.beginning_of_day + 1.hour
    ended = started + 30.minutes

    travel_to(started) do
      @monitor.update!(status: "down")
      @monitor.incidents.create!(started_at: started)
    end
    travel_to(ended) { @monitor.retire! }

    measured = travel_to(ended + 1.hour) do
      @monitor.down_seconds_during(Time.current.beginning_of_day...Time.current)
    end
    assert_equal 30.minutes.to_i, measured
  end

  # --- A stray ping resurrects nothing ---------------------------------------

  test "a success ping on a retired monitor is recorded but never transitions" do
    @monitor.retire!

    assert_difference -> { @monitor.ping_events.count }, 1 do
      assert_no_emails { @monitor.check_in! }
    end
    assert_equal "retired", @monitor.reload.status
  end

  # FailureReport has its OWN copy of the not-monitored guard. Without `retired`
  # in it, a still-running cron reporting status=1 flips the monitor to down,
  # opens an incident, emails a false outage and re-occupies a cap slot. A
  # success-ping-only test passes that broken implementation.
  test "a failure ping on a retired monitor is recorded but never transitions" do
    @monitor.retire!

    assert_no_difference -> { Incident.count } do
      assert_difference -> { @monitor.ping_events.count }, 1 do
        assert_no_emails { @monitor.check_in!(kind: "failure", error: "boom") }
      end
    end
    assert_equal "retired", @monitor.reload.status
    assert_equal "failure", @monitor.ping_events.sole.kind
  end

  # --- Reviving ---------------------------------------------------------------

  # The retirement window has no pings BY CONSTRUCTION — the task was declared
  # absent — so next_due_at is stale on virtually every revive. Routing revive
  # through reactivate_heartbeat! would call flag_missed!: a down email fired
  # during the deploy that restores the task, before the restored job could
  # possibly have run.
  test "reviving a long-retired monitor fires no alert and re-arms the clock" do
    @monitor.retire!

    revived_at = 3.days.from_now
    travel_to(revived_at) do
      assert_no_difference -> { Incident.count } do
        assert_no_emails { @monitor.revive! }
      end

      assert_equal "up", @monitor.reload.status
      assert_nil @monitor.status_before_retirement
      assert_in_delta revived_at + 1.hour, @monitor.next_due_at, 1.second
      assert_not @monitor.overdue_now?
    end
  end

  test "a revived monitor that then never runs goes down honestly, one window later" do
    @monitor.retire!
    revived_at = 3.days.from_now
    travel_to(revived_at) { @monitor.revive! }

    travel_to(revived_at + 1.hour + 4.minutes) do
      assert_empty Monitoring::Monitor.overdue.where(id: @monitor.id)
    end

    travel_to(revived_at + 1.hour + 6.minutes) do
      assert_includes Monitoring::Monitor.overdue.where(id: @monitor.id), @monitor
    end
  end

  # Pruning a monitor the user had paused must not destroy the pause.
  test "a paused monitor round-trips through retirement with no alert anywhere" do
    @monitor.pause!
    assert_no_emails do
      @monitor.retire!
      assert_equal "paused", @monitor.reload.status_before_retirement

      travel_to(3.days.from_now) { @monitor.revive! }
    end

    assert_equal "paused", @monitor.reload.status
    assert_nil @monitor.status_before_retirement
  end

  # DEVIATION (CLAUDE.md "say so"): §6.1 says revive restores `paused` and
  # otherwise sets `up`. A plan-suspended monitor is the third not-monitored
  # state, and reviving one to `up` would silently un-suspend a monitor a
  # downgrade deactivated — the cap-evasion CheckIn's own guard exists to stop.
  # Retirement changed nothing about it being unmonitored, so revive restores it.
  test "a suspended monitor is revived back to suspended, not to up" do
    @monitor.suspend!
    @monitor.retire!
    assert_equal "suspended", @monitor.reload.status_before_retirement

    @monitor.revive!
    assert_equal "suspended", @monitor.reload.status
  end

  test "reviving a monitor that is not retired does nothing" do
    @monitor.revive!
    assert_equal "up", @monitor.reload.status
  end

  # --- The sites retirement touches ------------------------------------------

  test "a retired monitor occupies no cap slot and is not detectable" do
    before = users(:carol).remaining_monitor_slots
    @monitor.update!(next_due_at: 2.hours.ago)

    @monitor.retire!

    assert_equal before + 1, users(:carol).reload.remaining_monitor_slots
    assert_empty Monitoring::Monitor.detectable.where(id: @monitor.id)
    assert_empty Monitoring::Monitor.overdue.where(id: @monitor.id)
  end

  # The rollup keys off monitored? and is automatic; the live day lists the
  # not-monitored statuses EXPLICITLY and would otherwise score a retired
  # monitor's today as phantom-100%.
  test "a retired monitor's live today stat reads no-data, not phantom 100%" do
    @monitor.update!(first_ping_at: 2.days.ago, created_at: 2.days.ago)
    @monitor.retire!

    assert_equal :no_data, @monitor.uptime_series(days: 1).last
    assert_nil @monitor.uptime_percent(days: 1)
  end
end
