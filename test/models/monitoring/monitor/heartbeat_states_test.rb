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

  test "grace_period_configured? reflects whether a grace period is set" do
    @up.grace_period_seconds = 300
    assert @up.grace_period_configured?

    @up.grace_period_seconds = 0
    refute @up.grace_period_configured?
  end
end
