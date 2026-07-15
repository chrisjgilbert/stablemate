require "application_system_test_case"

# S3 (create), S4 (pause/resume), S5 (rotate token), S7 (cap reached).
class MonitorsTest < ApplicationSystemTestCase
  setup do
    @alice = users(:alice)
    @project = @alice.projects.sole
    @project.monitors.delete_all # start clean so the count is predictable
  end

  # S3 — create a monitor (using a preset) and see the ping-URL card + curl snippet.
  test "S3: create a monitor and reveal the ping-URL card and curl snippet" do
    sign_in @alice
    first(:link, "New monitor").click

    fill_in "Name", with: "Nightly export"
    find("select[aria-label='Expected interval preset']").select("Hourly")
    find("select[aria-label='Grace period preset']").select("5 minutes")
    click_on "Create monitor"

    # Post-create detail state reveals the ping-URL card + curl snippet.
    assert_text "Nightly export"
    assert_selector "[data-testid='ping-url-card']"
    assert_selector "input[aria-label='Ping URL'][value*='/ping/']"
    assert_selector "input[aria-label='curl snippet'][value*='curl -fsS']"

    monitor = @alice.monitors.order(:created_at).last
    assert_equal 3600, monitor.expected_interval_seconds
    assert_equal 300, monitor.grace_period_seconds
  end

  # S4 — pause then resume; the badge tracks the status.
  test "S4: pause and resume a monitor" do
    monitor = @project.monitors.create!(name: "Pausable", expected_interval_seconds: 3600, grace_period_seconds: 300, status: "pending")
    sign_in @alice
    visit monitor_path(monitor)

    click_on "Pause"
    assert_text "Paused"

    click_on "Resume"
    refute_text "Paused"
  end

  # S5 — rotate the token on the detail page; the displayed ping URL changes.
  test "S5: rotate the ping token changes the displayed ping URL" do
    monitor = @project.monitors.create!(name: "Rotatable", expected_interval_seconds: 3600, grace_period_seconds: 300)
    sign_in @alice
    visit monitor_path(monitor)

    original = find("input[aria-label='Ping URL']").value
    accept_confirm { click_on "Rotate token" }

    assert_no_selector "input[aria-label='Ping URL'][value='#{original}']"
    assert_selector "input[aria-label='Ping URL'][value*='/ping/']"
  end

  # S8 — the dashboard rows link into the monitor's detail page (the only way to
  # reach it from the index). The link is stretched across the whole row.
  test "S8: clicking a monitor row opens its detail page" do
    monitor = @project.monitors.create!(name: "Clickable", expected_interval_seconds: 3600, grace_period_seconds: 300)
    sign_in @alice
    assert_text "Clickable" # on the index/dashboard

    within "##{ActionView::RecordIdentifier.dom_id(monitor, :row)}" do
      # The row's link covers the whole row (before:inset-0), so a click anywhere
      # on it — over the sparkline, not just the name — resolves to this link.
      assert find("a[href='#{monitor_path(monitor)}']")[:class].include?("before:inset-0")
      click_on monitor.name
    end

    assert_current_path monitor_path(monitor)
    assert_selector "[data-testid='ping-url-card']"
  end

  # S7 — at the cap, the New-monitor action shows the at-limit state and "5 / 5".
  test "S7: at the cap the dashboard shows the count and the at-limit state" do
    Stablemate::MAX_MONITORS_PER_USER.times do |i|
      @project.monitors.create!(name: "M#{i}", expected_interval_seconds: 3600, grace_period_seconds: 300)
    end
    sign_in @alice

    assert_text "#{Stablemate::MAX_MONITORS_PER_USER} / #{Stablemate::MAX_MONITORS_PER_USER}"
    assert_selector "[data-testid='at-limit']"
    refute_link "New monitor"
  end
end
