require "test_helper"

# [unit] Monitoring::Monitor::DowntimeWindow — how many seconds of a time window
# a monitor was down, summed from its incidents.
#
# One rule with two readers: the live intraday reading (Uptime#live_today_stat)
# and the nightly rollup (UptimeRollup#raw_down_seconds). They used to be
# separate near-identical implementations, which is how the uptime bar and the
# uptime percentage come to disagree about the same day.
class Monitoring::Monitor::DowntimeWindowTest < ActiveSupport::TestCase
  setup do
    @monitor = users(:alice).projects.sole.monitors.create!(
      name: "Downtime window target",
      expected_interval_seconds: 3600,
      grace_period_seconds: 300,
      status: "up",
      last_ping_at: 2.days.ago,
      next_due_at: 1.day.ago
    )
    @window_start = 3.days.ago.to_date.to_time(:utc)
    @window_end   = @window_start + 1.day
  end

  test "a monitor with no incidents was never down" do
    assert_equal 0, down_seconds
  end

  test "an incident inside the window counts its full duration" do
    incident(from: @window_start + 10.hours, to: @window_start + 12.hours)

    assert_equal 2.hours.to_i, down_seconds
  end

  test "an incident that began before the window is clamped to the window start" do
    incident(from: @window_start - 3.hours, to: @window_start + 1.hour)

    assert_equal 1.hour.to_i, down_seconds
  end

  test "an incident that resolved after the window is clamped to the window end" do
    incident(from: @window_end - 1.hour, to: @window_end + 5.hours)

    assert_equal 1.hour.to_i, down_seconds
  end

  test "an open incident counts through to the window end" do
    incident(from: @window_end - 4.hours, to: nil)

    assert_equal 4.hours.to_i, down_seconds
  end

  test "an incident entirely before the window contributes nothing" do
    incident(from: @window_start - 5.hours, to: @window_start - 4.hours)

    assert_equal 0, down_seconds
  end

  test "an incident entirely after the window contributes nothing" do
    incident(from: @window_end + 1.hour, to: @window_end + 2.hours)

    assert_equal 0, down_seconds
  end

  test "separate incidents in the window are summed" do
    incident(from: @window_start + 1.hour, to: @window_start + 2.hours)
    incident(from: @window_start + 5.hours, to: @window_start + 5.5.hours)

    assert_equal 1.5.hours.to_i, down_seconds
  end

  # A stranded open incident on a monitor nobody is watching must not extend
  # downtime to the end of the window for a period we weren't measuring.
  # Pause/suspend resolve incidents, so this is legacy data only.
  test "an open incident on a monitor that is no longer monitored contributes nothing" do
    incident(from: @window_start + 2.hours, to: nil)
    @monitor.update_column(:status, "paused")

    assert_equal 0, down_seconds
  end

  test "a resolved incident still counts on a monitor that is no longer monitored" do
    incident(from: @window_start + 2.hours, to: @window_start + 3.hours)
    @monitor.update_column(:status, "paused")

    assert_equal 1.hour.to_i, down_seconds
  end

  private
    # Through the record's facade, the way both real readers reach it.
    def down_seconds
      @monitor.down_seconds_during(@window_start...@window_end)
    end

    def incident(from:, to:)
      @monitor.incidents.create!(started_at: from, resolved_at: to, cause: "missed_ping")
    end
end
