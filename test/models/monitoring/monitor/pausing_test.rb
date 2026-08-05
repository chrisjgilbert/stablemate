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

  test "resume! returns a never-pinged monitor to pending" do
    monitor = monitors(:pending)
    monitor.pause!
    monitor.resume!
    assert monitor.pending?
  end

  test "resume! returns a recently-pinged monitor to up" do
    monitor = monitors(:up)
    monitor.pause!
    monitor.resume!
    assert monitor.up?
  end

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

  # WU-2 (H1) — leaving the monitored state must resolve the open incident, so a
  # paused monitor never carries a stranded outage that the rollup counts forever.
  test "pause! resolves the open incident of a down monitor" do
    monitor = monitors(:up)
    monitor.update!(next_due_at: 10.minutes.ago)
    monitor.flag_missed!
    assert monitor.incidents.open.exists?

    monitor.pause!

    assert monitor.paused?
    refute monitor.incidents.open.exists?, "pausing a down monitor must resolve its incident"
  end

  # WU-2 (H1) — the previously-stranded sequence: down -> pause -> ping while paused
  # (the user's cron keeps firing) -> resume must land on up with NO lingering
  # open incident that would otherwise render an "up" badge over a "down" banner.
  test "down, pause, ping, resume leaves the monitor up with no stranded incident" do
    monitor = monitors(:up)
    monitor.update!(next_due_at: 10.minutes.ago)
    monitor.flag_missed!
    assert monitor.down?

    monitor.pause!
    monitor.check_in!(received_at: Time.current)
    monitor.resume!

    assert monitor.up?
    refute monitor.incidents.open.exists?, "resume must not leave a stranded open incident"
  end

  # F11 — pause! used to read the open incident on an UNLOCKED connection and only
  # then flip the status, so a detection sweep landing in that window opened an
  # incident (and sent the down email the user was trying to silence) after the
  # read had already concluded there was nothing to resolve: `paused` WITH an open
  # incident, which the rollup then counts as downtime forever.
  #
  # The real race needs two committed connections, which transactional fixtures
  # can't give us, so this pins the invariant that closes it instead: the row lock
  # is acquired BEFORE the incident is read, exactly as every ping-path operation
  # (CheckIn / FailureReport / MissedPing) does it. With the lock held first, a
  # concurrent sweep either finishes before pause! (which then reloads and sees
  # the incident) or blocks until pause! commits and finds a non-`up` monitor.
  test "pause! takes the row lock before reading the open incident" do
    monitor = monitors(:up)
    monitor.update!(next_due_at: 10.minutes.ago)
    monitor.flag_missed!

    statements = sql_executed_during { monitor.pause! }
    locked_at  = statements.index { |sql| sql.match?(/FROM "monitors".*FOR UPDATE/m) }
    read_at    = statements.index { |sql| sql.match?(/FROM "incidents".*resolved_at/m) }

    assert locked_at, "pause! must lock the monitor row"
    assert read_at, "pause! must read the open incident"
    assert locked_at < read_at,
      "pause! must hold the row lock before reading the incident, or a racing sweep " \
      "can open one between the read and the flip"
  end

  # The other ordering: the sweep committed first, so the in-memory monitor is
  # stale (`up`, no incident). Reloading under the lock is what lets pause! see
  # the incident it must resolve.
  test "pause! resolves an incident opened after the monitor was loaded" do
    monitor = monitors(:up)
    Monitoring::Monitor.find(monitor.id).then do |sweep_copy|
      sweep_copy.update!(next_due_at: 10.minutes.ago)
      sweep_copy.flag_missed!
    end
    assert monitor.up?, "the in-memory copy is deliberately stale"

    monitor.pause!

    assert monitor.paused?
    refute monitor.incidents.open.exists?
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
