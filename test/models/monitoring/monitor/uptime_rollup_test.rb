require "test_helper"

# [unit] Monitoring::Monitor::UptimeRollup — reached via monitor.roll_up_uptime(day).
# Computes one day's up/down seconds + ping_count from incidents/pings and
# idempotently upserts the UptimeDayStat. Time is frozen everywhere it matters.
class Monitoring::Monitor::UptimeRollupTest < ActiveSupport::TestCase
  setup do
    @monitor = users(:alice).monitors.create!(
      name: "Rollup target",
      expected_interval_seconds: 3600,
      grace_period_seconds: 300,
      status: "up",
      last_ping_at: 2.days.ago,
      next_due_at: 1.day.ago
    )
    # The day under test: a full UTC calendar day in the past, fully within the
    # monitor's lifetime so it counts as measured (not no-data).
    @day = 3.days.ago.to_date
    @monitor.update_column(:created_at, (@day - 1.day).to_time(:utc))
  end

  def seconds_in_day = 86_400

  # Scenario 1 — up all day → 86400 up, 0 down, correct ping_count.
  test "a monitor up all day rolls up to a full up-day with the ping count" do
    3.times { |i| @monitor.ping_events.create!(received_at: @day.to_time(:utc) + (i * 3).hours, kind: "success") }
    # A ping the day before must not be counted.
    @monitor.ping_events.create!(received_at: (@day - 1.day).to_time(:utc) + 12.hours, kind: "success")

    stat = @monitor.roll_up_uptime(@day)

    assert_equal seconds_in_day, stat.up_seconds
    assert_equal 0, stat.down_seconds
    assert_equal 3, stat.ping_count
    assert_equal @day, stat.day
  end

  # Scenario 2 — an incident 10:00–12:00 UTC → down_seconds == 7200, rest up.
  test "an incident from 10:00 to 12:00 yields 7200 down seconds, the rest up" do
    @monitor.incidents.create!(
      started_at: @day.to_time(:utc) + 10.hours,
      resolved_at: @day.to_time(:utc) + 12.hours,
      cause: "missed_ping"
    )

    stat = @monitor.roll_up_uptime(@day)

    assert_equal 2.hours.to_i, stat.down_seconds
    assert_equal seconds_in_day - 2.hours.to_i, stat.up_seconds
  end

  # An incident that started before the day and is still open covers the whole day.
  test "an incident open across the whole day yields a fully-down day" do
    @monitor.incidents.create!(started_at: (@day - 1.day).to_time(:utc) + 6.hours, cause: "missed_ping")

    stat = @monitor.roll_up_uptime(@day)

    assert_equal seconds_in_day, stat.down_seconds
    assert_equal 0, stat.up_seconds
  end

  # Scenario 3 — a day fully before the monitor existed is no-data (0/0), not down.
  test "a day before the monitor existed is no-data, not down" do
    before_creation = (@monitor.created_at.to_date - 5.days)

    stat = @monitor.roll_up_uptime(before_creation)

    assert_equal 0, stat.up_seconds
    assert_equal 0, stat.down_seconds
    assert_equal :no_data, stat.status
  end

  # Scenario 3 (paused) — a day the monitor was paused for is no-data, not down.
  test "a fully paused day is no-data, not down" do
    @monitor.update!(status: "paused")

    stat = @monitor.roll_up_uptime(@day)

    assert_equal 0, stat.up_seconds
    assert_equal 0, stat.down_seconds
    assert_equal :no_data, stat.status
  end

  # Issue #19 — a plan-suspended monitor is "not monitored" just like paused, so a
  # day with no evidence (no pings, no incident) is no-data, NOT a phantom 100%-up
  # day. Without this a suspended monitor would back-fill false historical uptime.
  test "a fully suspended day is no-data, not down" do
    @monitor.update!(status: "suspended")

    stat = @monitor.roll_up_uptime(@day)

    assert_equal 0, stat.up_seconds
    assert_equal 0, stat.down_seconds
    assert_equal :no_data, stat.status
  end

  # Spec §3.1 — a pending (created, never pinged) monitor's evidence-free day is
  # no-data, not a false 100%-up day, and is excluded from uptime_percent.
  test "a pending never-pinged monitor's day is no-data, not a full up-day" do
    pending = users(:alice).monitors.create!(
      name: "Never pinged",
      expected_interval_seconds: 3600,
      grace_period_seconds: 300,
      status: "pending"
    )
    pending.update_column(:created_at, (@day - 1.day).to_time(:utc))

    stat = pending.roll_up_uptime(@day)

    assert_equal 0, stat.up_seconds
    assert_equal 0, stat.down_seconds
    assert_equal :no_data, stat.status
    # Excluded from the denominator → no measured data → nil percent.
    assert_nil pending.uptime_percent(days: 90)
  end

  # Scenario 4 — re-running the same day overwrites, never duplicates.
  test "re-running a day overwrites the same row rather than duplicating" do
    @monitor.roll_up_uptime(@day)
    @monitor.incidents.create!(
      started_at: @day.to_time(:utc) + 1.hour,
      resolved_at: @day.to_time(:utc) + 2.hours,
      cause: "missed_ping"
    )

    assert_no_difference -> { UptimeDayStat.count } do
      @monitor.roll_up_uptime(@day)
    end

    stat = @monitor.uptime_day_stats.find_by(day: @day)
    assert_equal 1.hour.to_i, stat.down_seconds
  end

  # Regression: re-rolling a past active day after the monitor is later paused
  # must NOT erase the real history (no pause-history table in Phase 2, so we key
  # off evidence — a day with pings/incidents stays measured).
  test "pausing later does not wipe a past day that actually saw pings" do
    @monitor.ping_events.create!(received_at: @day.to_time(:utc) + 2.hours, kind: "success")
    @monitor.update!(status: "paused")

    stat = @monitor.roll_up_uptime(@day)

    assert_equal seconds_in_day, stat.up_seconds
    assert_equal 1, stat.ping_count
    assert_equal :up, stat.status
  end

  # The monitor's creation day is only measured from creation onward (partial day).
  test "the creation day measures only the seconds after the monitor existed" do
    created_at = @day.to_time(:utc) + 6.hours
    @monitor.update_column(:created_at, created_at)

    stat = @monitor.roll_up_uptime(@day)

    assert_equal seconds_in_day - 6.hours.to_i, stat.up_seconds
    assert_equal 0, stat.down_seconds
  end
end
