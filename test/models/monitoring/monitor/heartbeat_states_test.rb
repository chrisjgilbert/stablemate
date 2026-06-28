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
end
