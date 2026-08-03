require "test_helper"

# [unit] Monitoring::Monitor::Uptime — presentation reads of the rolled-up data:
# the 90-element day-status series (oldest→newest, live current day), the overall
# uptime percent (no-data excluded), and the dashboard MiniTicks helper.
class Monitoring::Monitor::UptimeTest < ActiveSupport::TestCase
  setup do
    freeze_time
    @project = users(:alice).projects.sole
    @monitor = @project.monitors.create!(
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

  # Bug: a resolved-earlier-today incident must still show today as partial, not
  # a phantom green `up` — the live-today status previously only looked at the
  # currently-open incident and ignored one already recovered from.
  test "uptime_series shows today as partial after an incident resolved earlier today" do
    # Pin "now" to midday so the 06:00-09:00 incident below is unambiguously in
    # the past, regardless of what time of day this test actually runs.
    travel_to Date.current.to_time(:utc) + 12.hours

    @monitor.incidents.create!(
      started_at: Date.current.to_time(:utc) + 6.hours,
      resolved_at: Date.current.to_time(:utc) + 9.hours,
      cause: "missed_ping"
    )

    series = @monitor.uptime_series(days: 90)

    assert_equal :partial, series.last
  end

  test "uptime_series shows today as down when an open incident has covered all of today so far" do
    @monitor.incidents.create!(started_at: 1.day.ago, cause: "missed_ping")

    series = @monitor.uptime_series(days: 90)

    assert_equal :down, series.last
  end

  # Scenario 7 — overall % = up / (up + down), no-data excluded; hand fixture.
  test "uptime_percent is up over up-plus-down with no-data excluded" do
    # Pinned to 00:00 UTC so today's live segment has no elapsed seconds to
    # contribute — this case is about the persisted-day math. Today's live
    # blending gets its own cases below.
    travel_to Date.current.to_time(:utc)

    base = Date.current - 10
    # Day A: fully up (86400 up). Day B: half down (43200 up, 43200 down).
    @monitor.uptime_day_stats.create!(day: base, up_seconds: 86_400, down_seconds: 0, ping_count: 1)
    @monitor.uptime_day_stats.create!(day: base + 1, up_seconds: 43_200, down_seconds: 43_200, ping_count: 1)
    # Day C: no-data (0/0) — must be excluded from the denominator.
    @monitor.uptime_day_stats.create!(day: base + 2, up_seconds: 0, down_seconds: 0, ping_count: 0)

    # up = 129600, down = 43200 → 129600 / 172800 = 75.0
    assert_in_delta 75.0, @monitor.uptime_percent(days: 90), 0.01
  end

  # "—" is only honest when nothing at all has been measured — today included.
  test "uptime_percent is nil when nothing has been measured, today included" do
    never_pinged = @project.monitors.create!(
      name: "Never pinged", expected_interval_seconds: 3600, grace_period_seconds: 300, status: "pending"
    )

    assert_nil never_pinged.uptime_percent(days: 90)
  end

  # F8 (#51) — the probe: an all-green rolled history plus a resolved outage
  # today. Today has no UptimeDayStat until the 00:10 rollup, so the percent used
  # to sit at a stale 100.00% beside an amber today bar for up to 24h (and the
  # API served that number). The bar and the percent must read the same seconds.
  test "uptime_percent counts today's resolved outage before the nightly rollup" do
    travel_to Date.current.to_time(:utc) + 12.hours

    7.times do |i|
      @monitor.uptime_day_stats.create!(day: Date.current - (i + 1), up_seconds: 86_400, down_seconds: 0, ping_count: 24)
    end
    @monitor.incidents.create!(
      started_at: Date.current.to_time(:utc) + 6.hours,
      resolved_at: Date.current.to_time(:utc) + 9.hours,
      cause: "missed_ping"
    )

    percent = @monitor.uptime_percent(days: 90)

    # The bar says partial, so the percent may not say 100: up = 7*86_400 +
    # (43_200 elapsed - 10_800 down), down = 10_800 → 637_200 / 648_000.
    assert_equal :partial, @monitor.uptime_series(days: 90).last
    assert_in_delta 98.33, percent, 0.01
    assert_operator percent, :<, 100.0
  end

  # A monitor whose only data is today reports today's number, not "—".
  test "uptime_percent reflects today alone when nothing has been rolled up yet" do
    travel_to Date.current.to_time(:utc) + 12.hours

    @monitor.incidents.create!(
      started_at: Date.current.to_time(:utc) + 3.hours,
      resolved_at: Date.current.to_time(:utc) + 9.hours,
      cause: "missed_ping"
    )

    # 6h down out of the 12h elapsed today → 50%.
    assert_in_delta 50.0, @monitor.uptime_percent(days: 90), 0.01
  end

  # An OPEN incident is down up to NOW — the rest of the day hasn't elapsed and
  # must not be scored (that is exactly what the end-of-day clamp gets wrong).
  test "uptime_percent counts an open incident only up to now, not to end of day" do
    travel_to Date.current.to_time(:utc) + 12.hours

    @monitor.incidents.create!(started_at: Date.current.to_time(:utc) + 6.hours, cause: "missed_ping")

    # 6h up, 6h down of the 12h elapsed → 50%, not 6/24 up.
    assert_in_delta 50.0, @monitor.uptime_percent(days: 90), 0.01
  end

  # A not-monitored today (paused/suspended) is no-data, so it stays out of the
  # denominator — the same rule the bar applies to today's segment.
  test "uptime_percent excludes today while the monitor is paused" do
    travel_to Date.current.to_time(:utc) + 12.hours

    @monitor.uptime_day_stats.create!(day: Date.current - 1, up_seconds: 43_200, down_seconds: 43_200, ping_count: 1)
    @monitor.update!(status: "paused")

    assert_in_delta 50.0, @monitor.uptime_percent(days: 90), 0.01
  end

  # The monitor detail page and the API detail endpoint both render the bar AND
  # the percent, and each of those recomputed today's live stat from scratch — two
  # identical incident scans per render, for a number that also has to agree
  # between them.
  test "the live day's stat is computed once for the bar and the percent" do
    travel_to Date.current.to_time(:utc) + 12.hours
    @monitor.incidents.create!(started_at: Date.current.to_time(:utc) + 6.hours, cause: "missed_ping")

    scans = count_incident_scans do
      @monitor.uptime_series(days: 90)
      @monitor.uptime_percent(days: 90)
    end

    assert_equal 1, scans, "today's incidents should be scanned once per render, not once per reader"
  end

  # …but the snapshot is of a moment, so it must not outlive one. Nothing in a
  # request moves the clock; `travel_to` in a test does, and a memo that survived
  # it would quietly answer with the old time.
  test "the live day's stat is recomputed when the clock moves" do
    travel_to Date.current.to_time(:utc) + 6.hours
    @monitor.incidents.create!(started_at: Date.current.to_time(:utc) + 3.hours,
      resolved_at: Date.current.to_time(:utc) + 6.hours, cause: "missed_ping")

    # 3h up, 3h down of the 6h elapsed.
    assert_in_delta 50.0, @monitor.uptime_percent(days: 90), 0.01

    travel_to Date.current.to_time(:utc) + 12.hours

    # Six more hours of uptime on the same instance: 9h up, 3h down.
    assert_in_delta 75.0, @monitor.uptime_percent(days: 90), 0.01
  end

  # Recent events feed: pings + incident open/resolve, cause-aware labels
  # (job-failure-details.md §9).
  test "recent_events renders a success ping as a ping event" do
    @monitor.ping_events.create!(received_at: 1.minute.ago, duration_ms: 42)

    event = @monitor.recent_events.first

    assert_equal :ping, event.kind
    assert_equal "Ping received", event.label
    assert_equal 42, event.duration_ms
  end

  test "recent_events renders a failure ping as a failure event carrying the error" do
    @monitor.ping_events.create!(received_at: 1.minute.ago, kind: "failure",
                                 error: "RuntimeError: backup disk full")

    event = @monitor.recent_events.first

    assert_equal :failure, event.kind
    assert_equal "Error reported — RuntimeError: backup disk full", event.label
  end

  test "recent_events labels a missed_ping incident open as no ping received" do
    @monitor.incidents.create!(started_at: 1.minute.ago, cause: "missed_ping")

    event = @monitor.recent_events.first

    assert_equal :down, event.kind
    assert_equal "Went down — no ping received", event.label
  end

  test "recent_events labels a reported_error incident open as job reported an error" do
    @monitor.incidents.create!(started_at: 1.minute.ago, cause: "reported_error",
                               error: "RuntimeError: backup disk full")

    event = @monitor.recent_events.first

    assert_equal :down, event.kind
    assert_equal "Went down — job reported an error", event.label
  end

  # A reported failure's ping and its incident share one timestamp (the incident
  # opens AT received_at), and sort_by is unstable — the kind tiebreak keeps the
  # incident narrative leading deterministically.
  test "recent_events leads with the incident row when it ties its failure ping" do
    at = 1.minute.ago
    @monitor.ping_events.create!(received_at: at, kind: "failure", error: "boom")
    @monitor.incidents.create!(started_at: at, cause: "reported_error", error: "boom")

    kinds = @monitor.recent_events.map(&:kind)

    assert_equal [ :down, :failure ], kinds.first(2)
  end

  # M13 — mini_ticks_for ranks rows inside a window-function subquery, and the
  # outer SELECT's row order is not guaranteed to survive that under a different
  # plan. Newest-first per monitor is the contract mini_ticks reverses into the
  # sparkline, so pin it here rather than trust the planner.
  test "mini_ticks_for returns each monitor's kinds newest first" do
    other = @project.monitors.create!(
      name: "Second sparkline", expected_interval_seconds: 3600, grace_period_seconds: 300, status: "up"
    )

    # Written in a deliberately jumbled order, and interleaved between the two
    # monitors, so nothing but an explicit ordering can hand them back right.
    [
      [ other,    2, "failure" ],
      [ @monitor, 3, "success" ],
      [ other,    1, "failure" ],
      [ @monitor, 1, "success" ],
      [ other,    3, "success" ],
      [ @monitor, 4, "failure" ],
      [ @monitor, 2, "failure" ]
    ].each do |monitor, minutes_ago, kind|
      monitor.ping_events.create!(received_at: minutes_ago.minutes.ago, kind:)
    end

    ticks = Monitoring::Monitor.mini_ticks_for([ @monitor.id, other.id ])

    assert_equal %w[success failure success failure], ticks[@monitor.id]
    assert_equal %w[failure failure success], ticks[other.id]
    # …and the sparkline the dashboard draws from them runs oldest → newest.
    assert_equal %w[down up down up], @monitor.mini_ticks(kinds: ticks[@monitor.id])
  end

  # MiniTicks helper: last 16 ping events mapped to up/down ticks.
  test "mini_ticks maps the last 16 ping events to up and down ticks" do
    18.times do |i|
      @monitor.ping_events.create!(received_at: i.minutes.ago, kind: i.even? ? "success" : "failure")
    end

    ticks = @monitor.mini_ticks

    assert_equal 16, ticks.size
    assert(ticks.all? { |t| %w[up down].include?(t) })
  end

  private
    # How many times the block scans the incidents table — the query
    # live_today_stat runs, and the one the memoization is there to halve.
    def count_incident_scans
      scans = 0
      counter = ->(*, payload) { scans += 1 if payload[:sql] =~ /\bFROM "incidents"/i && payload[:name] != "SCHEMA" }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
      scans
    end
end
