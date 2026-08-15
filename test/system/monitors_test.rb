require "application_system_test_case"

# S4 (pause/resume), S7 (cap reached), S8 (row -> detail).
#
# S3 (create), S5 (rotate token) and S9 (the ping-URL card) went with the
# surfaces they drove: creation is `stablemate:sync`'s job now (v1-scope §3.1)
# and the token-in-the-URL credential is deleted (§3.2). The create flow's
# successor is the setup panel — see setup_panel_test.rb.
class MonitorsTest < ApplicationSystemTestCase
  setup do
    # carol owns no monitors, so this file's counts are only what it creates.
    @user = users(:carol)
    @project = @user.projects.sole
  end

  # S4 — pause then resume; the badge tracks the status.
  test "S4: pause and resume a monitor" do
    monitor = @project.monitors.create!(name: "Pausable", expected_interval_seconds: 3600, grace_period_seconds: 300, status: "pending")
    sign_in @user
    visit monitor_path(monitor)

    click_on "Pause"
    assert_text "Paused"

    click_on "Resume"
    refute_text "Paused"
  end

  # S8 — the dashboard rows link into the monitor's detail page (the only way to
  # reach it from the index). The link is stretched across the whole row.
  test "S8: clicking a monitor row opens its detail page" do
    monitor = @project.monitors.create!(name: "Clickable", expected_interval_seconds: 3600, grace_period_seconds: 300)
    sign_in @user
    assert_text "Clickable" # on the index/dashboard

    within "##{ActionView::RecordIdentifier.dom_id(monitor, :row)}" do
      # The row's link covers the whole row (before:inset-0), so a click anywhere
      # on it — over the sparkline, not just the name — resolves to this link.
      assert_includes find("a[href='#{monitor_path(monitor)}']")[:class], "before:inset-0"
      click_on monitor.name
    end

    assert_current_path monitor_path(monitor)
    # The detail page's own content, now that the ping-URL card is gone: the
    # read-only config panel §3.3 renders in the edit form's place.
    assert_selector "[data-testid='config-panel']"
  end

  # S7 — at the cap the dashboard shows the at-limit state and "5 / 5". The
  # `refute_link "New monitor"` this test used to end on is deleted rather than
  # kept: with no create affordance anywhere (§3.3), it would stay green while
  # proving nothing (§8).
  test "S7: at the cap the dashboard shows the count and the at-limit state" do
    Stablemate::MAX_MONITORS_PER_USER.times do |i|
      @project.monitors.create!(name: "M#{i}", expected_interval_seconds: 3600, grace_period_seconds: 300)
    end
    sign_in @user

    assert_text "#{Stablemate::MAX_MONITORS_PER_USER} / #{Stablemate::MAX_MONITORS_PER_USER}"
    assert_selector "[data-testid='at-limit']"
  end
end
