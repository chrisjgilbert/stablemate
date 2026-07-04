require "test_helper"

# Unit test for the Monitoring::Monitor::CheckIn operation, reached via
# monitor.check_in!.
class Monitoring::Monitor::CheckInTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup { @monitor = monitors(:pending) }

  test "records a success PingEvent" do
    assert_difference -> { @monitor.ping_events.count }, 1 do
      @monitor.check_in!(received_at: Time.current)
    end

    event = @monitor.ping_events.order(:received_at).last
    assert_equal "success", event.kind
    # Rails' default timestamping still fills created_at (no manual plumbing).
    assert event.created_at.present?
  end

  test "moves last_ping_at and next_due_at by the expected interval" do
    freeze_time do
      now = Time.current
      @monitor.check_in!(received_at: now)

      assert_equal now, @monitor.last_ping_at
      assert_equal now + @monitor.expected_interval_seconds.seconds, @monitor.next_due_at
    end
  end

  test "transitions a pending monitor to up" do
    assert_equal "pending", @monitor.status
    @monitor.check_in!(received_at: Time.current)
    assert_equal "up", @monitor.status
  end

  test "leaves an up monitor up (timestamps only, no Phase 1 transitions)" do
    up = monitors(:up)
    up.check_in!(received_at: Time.current)
    assert_equal "up", up.status
  end

  test "captures source_ip and duration_ms when given" do
    @monitor.check_in!(received_at: Time.current, source_ip: "203.0.113.7", duration_ms: 1234)

    event = @monitor.ping_events.order(:received_at).last
    assert_equal "203.0.113.7", event.source_ip
    assert_equal 1234, event.duration_ms
  end

  test "persists the moved timestamps to the database" do
    freeze_time do
      @monitor.check_in!(received_at: Time.current)
      @monitor.reload
      assert_equal Time.current, @monitor.last_ping_at
    end
  end

  # Scenario 24 — down -> up: resolves the open incident, enqueues one recovered email.
  test "a down monitor recovering resolves its incident and enqueues one recovered email" do
    down = monitors(:up)
    down.update!(next_due_at: 10.minutes.ago) # overdue, so detection flags it
    down.flag_missed!
    incident = down.incidents.open.sole

    freeze_time do
      assert_enqueued_emails 1 do
        down.check_in!(received_at: Time.current)
      end

      assert down.reload.up?
      assert_equal Time.current, incident.reload.resolved_at
      refute incident.open?
      recovered = down.notifications.where(event: "recovered").sole
      assert recovered.delivered_at.present?
    end
  end

  # Scenario 25 — an up monitor receiving a ping sends no notification.
  test "an up monitor receiving a ping enqueues no email" do
    up = monitors(:up)
    assert_enqueued_emails 0 do
      up.check_in!(received_at: Time.current)
    end
    assert up.up?
  end

  # Scenario 26 — a paused monitor records the event but stays paused, sends nothing.
  test "a paused monitor records the ping but stays paused and alerts nothing" do
    paused = monitors(:up)
    paused.pause!

    assert_difference -> { paused.ping_events.count }, 1 do
      assert_enqueued_emails 0 do
        paused.check_in!(received_at: Time.current)
      end
    end

    assert paused.reload.paused?
  end

  # Issue #19 — a suspended (plan-downgraded) monitor records the event but stays
  # suspended and alerts nothing. A stray ping must NOT silently flip it back to
  # `up`: that would re-enter the cap count and resume free monitoring for a user
  # who is over the Free cap, defeating the downgrade gate.
  test "a suspended monitor records the ping but stays suspended and alerts nothing" do
    suspended = monitors(:up)
    suspended.suspend!

    assert_difference -> { suspended.ping_events.count }, 1 do
      assert_enqueued_emails 0 do
        suspended.check_in!(received_at: Time.current)
      end
    end

    assert suspended.reload.suspended?
  end

  # Spec §3.7 — a down monitor with NO open incident recovers to up but must not
  # emit a spurious incident-less recovery email or Notification row.
  test "an incident-less down monitor recovers to up with no recovery alert" do
    monitor = monitors(:up)
    monitor.update!(status: "down") # down without any incident

    assert_no_difference -> { monitor.notifications.count } do
      assert_enqueued_emails 0 do
        monitor.check_in!(received_at: Time.current)
      end
    end

    assert monitor.reload.up?
  end

  # WU-1 (M1) — the DB backstop: at most one recovered notification per incident.
  test "a second recovered notification for one incident is rejected by the unique index" do
    down = monitors(:up)
    down.update!(next_due_at: 10.minutes.ago) # overdue, so detection flags it
    down.flag_missed!
    incident = down.incidents.open.sole

    down.notifications.create!(incident:, channel: "email", event: "recovered")
    assert_raises(ActiveRecord::RecordNotUnique) do
      down.notifications.create!(incident:, channel: "email", event: "recovered")
    end
  end

  # WU-1 (M1) — a recovery that races a concurrent recovery (its recovered
  # notification already exists) resolves the incident once, sends one email, and
  # never raises the unique-index violation up the public ping path.
  test "recovering does not double the recovered notification" do
    down = monitors(:up)
    down.update!(next_due_at: 10.minutes.ago) # overdue, so detection flags it
    down.flag_missed!
    incident = down.incidents.open.sole
    # Simulate a concurrent recovery that already inserted the recovered row.
    down.notifications.create!(incident:, channel: "email", event: "recovered")

    assert_nothing_raised do
      down.check_in!(received_at: Time.current)
    end

    assert_equal 1, down.notifications.where(event: "recovered").count
    assert down.reload.up?
  end
end
