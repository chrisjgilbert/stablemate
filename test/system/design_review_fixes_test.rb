require "application_system_test_case"

# Browser-driven Definition-of-Done gates for the design-review remediation
# (docs/specs/design-review-fixes.md §4). One robust flow per work unit.
class DesignReviewFixesTest < ApplicationSystemTestCase
  setup { @alice = users(:alice) }

  # S-DR1 (WU-2, H1) — pausing a DOWN monitor clears its incident, and after a
  # ping + resume the badge returns to Up with no lingering "down" banner. This is
  # the flow that previously stranded an open incident behind an "up" badge.
  test "S-DR1: pausing a down monitor clears the incident and resume returns it to up" do
    monitor = @alice.monitors.create!(
      name: "Flaky job", expected_interval_seconds: 3600, grace_period_seconds: 300,
      status: "up", last_ping_at: 2.hours.ago, next_due_at: 90.minutes.ago
    )
    monitor.flag_missed! # overdue -> down, opens the incident + banner

    sign_in @alice
    visit monitor_path(monitor)
    assert_selector "[data-testid='incident-banner']"

    # Pause resolves the open incident, so the banner disappears immediately.
    click_on "Pause"
    assert_text "Paused"
    assert_no_selector "[data-testid='incident-banner']"

    # The job's cron keeps firing while paused (a machine ping, not a UI action).
    monitor.check_in!(received_at: Time.current)

    click_on "Resume"
    assert_no_text "Paused"
    assert_no_selector "[data-testid='incident-banner']"
    assert_selector "##{dom_id(monitor, :badge)}", text: "Up"
  end
end
