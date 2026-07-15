require "test_helper"

# [unit] Monitoring::Monitor::UptimeRollup — reached via monitor.roll_up_uptime(day).
# Computes one day's up/down seconds + ping_count from incidents/pings and
# idempotently upserts the UptimeDayStat. Time is frozen everywhere it matters.
class Monitoring::Monitor::UptimeRollupTest < ActiveSupport::TestCase
  setup do
    @project = users(:alice).projects.sole
    @monitor = @project.monitors.create!(
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
    # This monitor has pinged (last_ping_at set), so its first ping predates the
    # day under test — the WU-10 measurement floor (a never-pinged monitor is
    # no-data) must not clip it.
    @monitor.update_column(:first_ping_at, (@day - 1.day).to_time(:utc))
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
    pending = @project.monitors.create!(
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

  # WU-2 (H1) — a not-measured monitor (paused) carrying a lingering OPEN incident
  # must not accrue full-day downtime; the day is no-data, not fully down. (Post-WU-2
  # pause resolves incidents, so this guards legacy/anomalous stranded incidents.)
  test "a paused monitor with a lingering open incident does not accrue downtime" do
    @monitor.incidents.create!(started_at: @day.to_time(:utc) + 1.hour, cause: "missed_ping")
    @monitor.update!(status: "paused")

    stat = @monitor.roll_up_uptime(@day)

    assert_equal 0, stat.down_seconds
    assert_equal 0, stat.up_seconds
    assert_equal :no_data, stat.status
  end

  # WU-10 (M8) — days entirely before the first ping are no-data, not phantom 100%
  # up, even when a late backfill rolls them while the monitor is already `up`.
  test "days before the first ping are no-data, even on a late backfill" do
    m = @project.monitors.create!(
      name: "Late first ping", expected_interval_seconds: 3600, grace_period_seconds: 300, status: "up"
    )
    m.update_column(:created_at, (@day - 2.days).to_time(:utc)) # existed 2 days before @day
    m.update_column(:first_ping_at, @day.to_time(:utc) + 6.hours) # but first pinged ON @day at 06:00

    # A full day before the first ping → no-data, not 100% up.
    before = @day - 1.day
    stat = m.roll_up_uptime(before)
    assert_equal 0, stat.up_seconds
    assert_equal 0, stat.down_seconds
    assert_equal :no_data, stat.status

    # The first-ping day is measured only from the first ping onward.
    day_stat = m.roll_up_uptime(@day)
    assert_equal seconds_in_day - 6.hours.to_i, day_stat.up_seconds
  end

  # WU-10 — a never-pinged monitor has no measured time at all (nil first_ping_at).
  test "a never-pinged monitor's day is no-data regardless of current status" do
    m = @project.monitors.create!(
      name: "Silent", expected_interval_seconds: 3600, grace_period_seconds: 300, status: "up"
    )
    m.update_column(:created_at, (@day - 1.day).to_time(:utc)) # first_ping_at stays nil

    stat = m.roll_up_uptime(@day)
    assert_equal 0, stat.up_seconds
    assert_equal 0, stat.down_seconds
    assert_equal :no_data, stat.status
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
