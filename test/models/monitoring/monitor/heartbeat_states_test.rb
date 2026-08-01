require "test_helper"

# State predicates + the detection scopes (scenarios 16-18, 22).
class Monitoring::Monitor::HeartbeatStatesTest < ActiveSupport::TestCase
  setup { @up = monitors(:up) }

  test "predicates reflect status" do
    @up.status = "down"
    assert @up.down?
    refute @up.up?
  end

  # Scenario 16 — an up monitor past interval+grace is overdue (eligible for down).
  test "overdue includes an up monitor whose grace window has fully elapsed" do
    travel_to @up.next_due_at + @up.grace_period_seconds.seconds + 1.second do
      assert_includes Monitoring::Monitor.overdue, @up
    end
  end

  # Scenario 22 — a monitor still within interval+grace is not overdue.
  test "overdue excludes a monitor still inside its grace window" do
    travel_to @up.next_due_at + @up.grace_period_seconds.seconds - 1.second do
      refute_includes Monitoring::Monitor.overdue, @up
    end
  end

  # Scenario 17 — pending is never overdue (never pinged, nothing due yet).
  test "overdue excludes pending monitors regardless of next_due_at" do
    pending = monitors(:pending)
    pending.update_columns(next_due_at: 1.year.ago)
    assert_empty Monitoring::Monitor.overdue.where(id: pending.id)
  end

  # Scenario 18 — paused is excluded from detection regardless of next_due_at.
  test "overdue excludes paused monitors regardless of next_due_at" do
    @up.update_columns(status: "paused", next_due_at: 1.year.ago)
    assert_empty Monitoring::Monitor.overdue.where(id: @up.id)
  end

  test "due_with_grace_at adds the grace to next_due_at" do
    assert_equal @up.next_due_at + @up.grace_period_seconds.seconds, @up.due_with_grace_at
  end

  test "next_check_upcoming? is true for an up monitor whose next_due_at hasn't passed" do
    assert @up.next_check_upcoming?
  end

  # A monitor stays "up" for its whole grace window after next_due_at passes
  # (detection only flips it to down once the grace window fully elapses) —
  # next_due_at is stale in that window, so it must not read as upcoming.
  test "next_check_upcoming? is false once next_due_at has passed, even though still up and within grace" do
    @up.update_columns(next_due_at: 1.minute.ago)
    refute @up.next_check_upcoming?
  end

  test "next_check_upcoming? is false without a next_due_at (never pinged)" do
    pending = monitors(:pending)
    assert_nil pending.next_due_at
    refute pending.next_check_upcoming?
  end

  test "next_check_upcoming? is false for a non-up monitor even with a future next_due_at" do
    @up.status = "paused"
    refute @up.next_check_upcoming?
  end

  # F7 — next_due_at used to be written only by register_contact, so an interval
  # edit left the OLD cadence driving detection: loosening hourly -> daily kept
  # the hourly due time and guaranteed a false `down` about an hour later, while
  # a grace edit applied instantly (the scope reads the live column). The
  # asymmetry is the trap. Recomputing on the model means every write path — the
  # edit form, the gem sync, the console — gets it.
  test "loosening the interval pushes next_due_at out from the last ping" do
    @up.update!(expected_interval_seconds: 1.day.to_i)

    assert_equal @up.last_ping_at + 1.day, @up.reload.next_due_at
    refute_includes Monitoring::Monitor.overdue, @up
  end

  test "tightening the interval pulls next_due_at in from the last ping" do
    @up.update!(expected_interval_seconds: 60)

    assert_equal @up.last_ping_at + 60.seconds, @up.reload.next_due_at
  end

  # A never-pinged monitor has nothing to measure from: next_due_at stays nil
  # (register_contact writes the first one) rather than being invented from now.
  test "an interval edit leaves next_due_at nil when the monitor has never pinged" do
    pending = monitors(:pending)
    pending.update!(expected_interval_seconds: 60)

    assert_nil pending.reload.next_due_at
  end

  # Recomputing for a not-monitored monitor is harmless — `overdue` only scans
  # `up` — and keeps the column honest for when it resumes.
  test "an interval edit still recomputes next_due_at on a paused monitor" do
    @up.pause!
    @up.update!(expected_interval_seconds: 60)

    assert_equal @up.last_ping_at + 60.seconds, @up.reload.next_due_at
  end

  # Only the interval feeds next_due_at; grace is added on read (due_with_grace_at
  # / the overdue scope), so editing it must not disturb the stored due time.
  test "editing anything other than the interval leaves next_due_at alone" do
    original = @up.next_due_at
    @up.update!(grace_period_seconds: 60, name: "Renamed")

    assert_equal original, @up.reload.next_due_at
  end

  test "grace_period_configured? reflects whether a grace period is set" do
    @up.grace_period_seconds = 300
    assert @up.grace_period_configured?

    @up.grace_period_seconds = 0
    refute @up.grace_period_configured?
  end
end
