require "application_system_test_case"

# Phase 2 required system tests (S8–S10), browser-driven via Cuprite/CDP. They
# drive the rendered UI and assert what the owner sees: the 90-day uptime panel,
# the dashboard sparkline, and the active-incident banner clearing on recovery.
class UptimeHistoryTest < ApplicationSystemTestCase
  include ActiveJob::TestHelper

  setup do
    Monitoring::Monitor.delete_all
    @alice = users(:alice)
    @project = @alice.projects.sole
  end

  # S8 — Detail uptime panel: 90-bar UptimeBar, overall % matching a fixture, and
  # the recent-events list with mono timestamps + duration_ms where present.
  test "S8: detail page renders the 90-day uptime bar, overall percent, and recent events" do
    # Noon UTC, so today's live half-day is an exact 43_200 seconds (#51 / F8:
    # the percent blends today in, so the fixture has to pin the clock).
    travel_to Date.current.to_time(:utc) + 12.hours

    monitor = @project.monitors.create!(
      name: "History job",
      expected_interval_seconds: 3600,
      grace_period_seconds: 300,
      status: "up"
    )
    monitor.update_column(:created_at, 100.days.ago)

    # Hand-computed fixture: one fully-up day (86_400 up) + one half-down day
    # (43_200/43_200) + today, which is half elapsed at noon and spent 6h of it
    # down (03:00–09:00, already recovered) → 21_600 up / 21_600 down.
    # up = 151_200, down = 64_800 → 151_200 / 216_000 = 70.00%.
    base = Date.current - 10
    monitor.uptime_day_stats.create!(day: base, up_seconds: 86_400, down_seconds: 0, ping_count: 24)
    monitor.uptime_day_stats.create!(day: base + 1, up_seconds: 43_200, down_seconds: 43_200, ping_count: 12)
    monitor.incidents.create!(
      started_at: Date.current.to_time(:utc) + 3.hours,
      resolved_at: Date.current.to_time(:utc) + 9.hours,
      cause: "missed_ping"
    )

    # A ping carrying a duration so the events list shows it.
    monitor.ping_events.create!(received_at: 5.minutes.ago, kind: "success", duration_ms: 142)

    sign_in @alice
    visit monitor_path(monitor)

    within "[data-testid='uptime-panel']" do
      # UptimeBar renders 90 day bars (rounded-[2px]).
      assert_equal 90, all("span.rounded-\\[2px\\]", visible: :all).size
      # Today's outage shows amber on the bar AND in the number: the two read the
      # same seconds, so a stale 100.00% next to an amber bar is impossible.
      assert_selector "span[title='today'].bg-chart-partial", visible: :all
      assert_selector "[data-testid='uptime-percent']", text: "70.00%"
    end

    within "[data-testid='recent-events']" do
      assert_selector "[data-testid='event-duration']", text: "142ms"
      # Mono UTC timestamp.
      assert_text(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC/)
    end
  end

  test "S9: dashboard row renders the mini-ticks sparkline and an uptime percent" do
    monitor = @project.monitors.create!(
      name: "Sparkline job",
      expected_interval_seconds: 3600,
      grace_period_seconds: 300,
      status: "up"
    )
    16.times { |i| monitor.ping_events.create!(received_at: (i + 1).minutes.ago, kind: "success") }

    sign_in @alice
    visit monitors_path

    within "##{dom_id(monitor, :row)}" do
      within "[data-testid='mini-ticks']" do
        assert_equal 16, all("span.rounded-\\[1\\.5px\\]", visible: :all).size
        assert_text "100%"
      end
    end
  end

  # S10 — Active-incident banner: red banner with expected-by, grace elapsed,
  # "down for …", NO Acknowledge button; clears + badge returns to Up on recovery.
  test "S10: a down monitor shows the incident banner with no Acknowledge, clearing on recovery" do
    monitor = @project.monitors.create!(
      name: "Down watch",
      expected_interval_seconds: 3600,
      grace_period_seconds: 300
    )

    # Ping it Up, then drive it Down via real detection under travel_to.
    Capybara.using_session(:pinger) { visit ping_path(monitor.ping_token) }
    assert monitor.reload.up?

    travel_to monitor.due_with_grace_at + 1.minute do
      perform_enqueued_jobs { DetectMissedPingsJob.perform_now }
    end
    assert monitor.reload.down?

    sign_in @alice
    visit monitor_path(monitor)

    within "[data-testid='incident-banner']" do
      assert_text "Monitor is down"
      assert_selector "[data-testid='expected-by']"
      assert_selector "[data-testid='grace-elapsed']", text: "elapsed"
      assert_selector "[data-testid='down-for']"
    end
    assert_no_button "Acknowledge"
    assert_no_text "Acknowledge"
    assert_selector "##{dom_id(monitor, :badge)}", text: "Down"

    # A recovering ping clears the banner and flips the badge back to Up (Turbo).
    perform_enqueued_jobs do
      Capybara.using_session(:pinger) { visit ping_path(monitor.ping_token) }
    end

    assert_selector "##{dom_id(monitor, :badge)}", text: "Up"
    assert monitor.reload.up?
    visit monitor_path(monitor)
    assert_no_selector "[data-testid='incident-banner']"
  end
end
