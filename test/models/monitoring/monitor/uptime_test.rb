require "test_helper"

# [unit] Monitoring::Monitor::Uptime — presentation reads of the rolled-up data:
# the 90-element day-status series (oldest→newest, live current day), the overall
# uptime percent (no-data excluded), and the dashboard MiniTicks helper.
class Monitoring::Monitor::UptimeTest < ActiveSupport::TestCase
  setup do
    freeze_time
    @monitor = users(:alice).monitors.create!(
      name: "Uptime read",
      expected_interval_seconds: 3600,
      grace_period_seconds: 300,
      status: "up",
      last_ping_at: 5.minutes.ago,
      next_due_at: 55.minutes.from_now
    )
    @monitor.update_column(:created_at, 200.days.ago)
  end

  teardown { unfreeze_time }

  # Scenario 6 — the series has 90 elements, oldest→newest, with the live today bucket.
  test "uptime_series returns 90 day statuses oldest to newest including a live today" do
    series = @monitor.uptime_series(days: 90)

    assert_equal 90, series.size
    assert(series.all? { |s| %i[up partial down no_data].include?(s) })
    # The last element is today, computed live: an up monitor with no incident is up.
    assert_equal :up, series.last
  end

  test "uptime_series reflects a stored day's status at the right position" do
    yesterday = Date.current - 1
    @monitor.uptime_day_stats.create!(day: yesterday, up_seconds: 80_000, down_seconds: 6_400, ping_count: 1)

    series = @monitor.uptime_series(days: 90)

    # Position: today is index 89, yesterday index 88.
    assert_equal :partial, series[88]
  end

  test "uptime_series marks a day with no stat and before nothing as no_data" do
    series = @monitor.uptime_series(days: 90)
    # No stats stored and today is the only live day → earlier days are no_data.
    assert_equal :no_data, series.first
  end

  # Scenario 7 — overall % = up / (up + down), no-data excluded; hand fixture.
  test "uptime_percent is up over up-plus-down with no-data excluded" do
    base = Date.current - 10
    # Day A: fully up (86400 up). Day B: half down (43200 up, 43200 down).
    @monitor.uptime_day_stats.create!(day: base, up_seconds: 86_400, down_seconds: 0, ping_count: 1)
    @monitor.uptime_day_stats.create!(day: base + 1, up_seconds: 43_200, down_seconds: 43_200, ping_count: 1)
    # Day C: no-data (0/0) — must be excluded from the denominator.
    @monitor.uptime_day_stats.create!(day: base + 2, up_seconds: 0, down_seconds: 0, ping_count: 0)

    # up = 129600, down = 43200 → 129600 / 172800 = 75.0
    assert_in_delta 75.0, @monitor.uptime_percent(days: 90), 0.01
  end

  test "uptime_percent is nil when there is no measured data" do
    assert_nil @monitor.uptime_percent(days: 90)
  end

  # MiniTicks helper: last 16 ping events mapped to up/down ticks.
  test "mini_ticks maps the last 16 ping events to up and down ticks" do
    18.times do |i|
      @monitor.ping_events.create!(received_at: i.minutes.ago, kind: i.even? ? "success" : "missed")
    end

    ticks = @monitor.mini_ticks

    assert_equal 16, ticks.size
    assert(ticks.all? { |t| %w[up down].include?(t) })
  end
end
