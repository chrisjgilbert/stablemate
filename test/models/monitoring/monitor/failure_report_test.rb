require "test_helper"

# Unit test for the Monitoring::Monitor::FailureReport operation, reached via
# monitor.check_in!(kind: "failure") — job-failure-details.md §5.
class Monitoring::Monitor::FailureReportTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup { @monitor = monitors(:up) }

  test "records a failure PingEvent carrying the error" do
    assert_difference -> { @monitor.ping_events.count }, 1 do
      @monitor.check_in!(kind: "failure", error: "RuntimeError: boom")
    end

    event = @monitor.ping_events.order(:received_at).last
    assert_equal "failure", event.kind
    assert_equal "RuntimeError: boom", event.error
  end

  test "moves last_ping_at and next_due_at by the expected interval" do
    freeze_time do
      now = Time.current
      @monitor.check_in!(received_at: now, kind: "failure", error: "boom")
      @monitor.reload

      assert_equal now, @monitor.last_ping_at
      assert_equal now + @monitor.expected_interval_seconds.seconds, @monitor.next_due_at
    end
  end

  # A failure is contact: measurement starts (§5 — the alternative reads as
  # "not monitored" when it's "down"). Never moved afterward, same as CheckIn.
  test "sets first_ping_at on the first failure only" do
    pending = monitors(:pending)
    assert_nil pending.first_ping_at

    freeze_time do
      first = Time.current
      pending.check_in!(received_at: first, kind: "failure", error: "boom")
      assert_equal first, pending.reload.first_ping_at

      travel 1.hour
      pending.check_in!(received_at: Time.current, kind: "failure", error: "boom")
      assert_equal first, pending.reload.first_ping_at
    end
  end

  test "truncates the error to ERROR_MESSAGE_LIMIT on the event and the incident" do
    long = "e" * (Stablemate::ERROR_MESSAGE_LIMIT + 50)
    @monitor.check_in!(kind: "failure", error: long)

    event = @monitor.ping_events.order(:received_at).last
    assert_equal Stablemate::ERROR_MESSAGE_LIMIT, event.error.length
    incident = @monitor.incidents.open.sole
    assert_equal Stablemate::ERROR_MESSAGE_LIMIT, incident.error.length
  end

  # Transition table row: up -> down, one reported_error incident, one down email.
  test "an up monitor goes down, opens a reported_error incident with the error, and enqueues one down email" do
    assert_difference -> { @monitor.incidents.count }, 1 do
      assert_enqueued_emails 1 do
        @monitor.check_in!(kind: "failure", error: "RuntimeError: boom")
      end
    end

    assert @monitor.reload.down?
    incident = @monitor.incidents.open.sole
    assert_equal "reported_error", incident.cause
    assert_equal "RuntimeError: boom", incident.error
    notification = @monitor.notifications.sole
    assert_equal "down", notification.event
    assert notification.delivered_at.present?
  end

  # Transition table row: pending -> down (§12-C — the first-ever signal being
  # "I failed" is exactly when a new user most needs the loop to work).
  test "a pending monitor goes down with an incident and a down email" do
    pending = monitors(:pending)

    assert_difference -> { pending.incidents.count }, 1 do
      assert_enqueued_emails 1 do
        pending.check_in!(kind: "failure", error: "boom")
      end
    end

    assert pending.reload.down?
    assert_equal "reported_error", pending.incidents.open.sole.cause
  end

  # Transition table row: down -> event only; the open incident keeps its
  # original cause/error (§12-B) and nothing re-alerts (§5.1's noise ceiling).
  test "a failure while already down records the event but opens no incident and sends no email" do
    @monitor.update!(next_due_at: 10.minutes.ago) # overdue, so detection flags it
    @monitor.flag_missed!
    incident = @monitor.incidents.open.sole
    assert_equal "missed_ping", incident.cause

    assert_difference -> { @monitor.ping_events.count }, 1 do
      assert_no_difference -> { @monitor.incidents.count } do
        assert_enqueued_emails 0 do
          @monitor.check_in!(kind: "failure", error: "boom")
        end
      end
    end

    assert @monitor.reload.down?
    incident.reload
    assert_equal "missed_ping", incident.cause
    assert_nil incident.error
  end

  # §12-B — a second reported error during the same open incident keeps the
  # FIRST error (it's what the down email said).
  test "a repeat failure keeps the incident's original error" do
    @monitor.check_in!(kind: "failure", error: "first error")
    incident = @monitor.incidents.open.sole

    @monitor.check_in!(kind: "failure", error: "second error")

    assert_equal "first error", incident.reload.error
    assert_equal 1, @monitor.incidents.count
  end

  # Transition table row: paused/suspended -> event only, no transition, no alert
  # (exactly CheckIn's rule — a stray ping of either polarity must not resume or
  # alert a deliberately-unmonitored monitor).
  test "a paused monitor records the failure but stays paused and alerts nothing" do
    @monitor.pause!

    assert_difference -> { @monitor.ping_events.count }, 1 do
      assert_no_difference -> { @monitor.incidents.count } do
        assert_enqueued_emails 0 do
          @monitor.check_in!(kind: "failure", error: "boom")
        end
      end
    end

    assert @monitor.reload.paused?
  end

  test "a suspended monitor records the failure but stays suspended and alerts nothing" do
    @monitor.suspend!

    assert_difference -> { @monitor.ping_events.count }, 1 do
      assert_no_difference -> { @monitor.incidents.count } do
        assert_enqueued_emails 0 do
          @monitor.check_in!(kind: "failure", error: "boom")
        end
      end
    end

    assert @monitor.reload.suspended?
  end

  # Facade routing (§5): kind selects the operation; the default stays CheckIn.
  test "check_in! with the default kind still records a success and goes up" do
    pending = monitors(:pending)
    pending.check_in!

    assert pending.reload.up?
    assert_equal "success", pending.ping_events.order(:received_at).last.kind
  end

  test "a nil error is stored as nil, not an empty string" do
    @monitor.check_in!(kind: "failure", error: nil)

    assert_nil @monitor.ping_events.order(:received_at).last.error
    assert_nil @monitor.incidents.open.sole.error
  end

  # Recovery needs zero new code (§5): the next success resolves the
  # reported_error incident and sends the one recovered email.
  test "a success after a reported error recovers the monitor with one recovered email" do
    @monitor.check_in!(kind: "failure", error: "boom")
    incident = @monitor.incidents.open.sole

    assert_enqueued_emails 1 do
      @monitor.check_in!
    end

    assert @monitor.reload.up?
    refute incident.reload.open?
  end
end
