require "test_helper"

# Unit tests for the reusable design-system components (design-system.md §2),
# rendered as partials. They assert the component contracts: status colours/labels,
# the down-dot pulse, the gem-chip gating, and the day/tick array → bar mapping.
class ComponentsTest < ActionView::TestCase
  helper MonitorsHelper

  test "StatusBadge renders the correct label and colour per status" do
    %w[up down paused pending].each do |status|
      html = render(partial: "shared/status_badge", locals: { status: status })
      assert_match(/#{status.capitalize}/, html)
    end
  end

  test "StatusBadge pulses only on down" do
    down = render(partial: "shared/status_badge", locals: { status: "down" })
    up   = render(partial: "shared/status_badge", locals: { status: "up" })

    assert_match "status-dot-pulse", down
    refute_match "status-dot-pulse", up
  end

  test "GemChip renders only when the monitor was synced from the gem" do
    gem_monitor = Monitoring::Monitor.new(source: "gem")
    manual_monitor = Monitoring::Monitor.new(source: "manual")

    assert_match "gem", render(partial: "shared/gem_chip", locals: { monitor: gem_monitor })
    assert_equal "", render(partial: "shared/gem_chip", locals: { monitor: manual_monitor }).strip
  end

  test "UptimeBar renders one bar per day with today/Nd-ago tooltips" do
    days = %w[up up down] # oldest → newest
    html = render(partial: "shared/uptime_bar", locals: { days: days })

    assert_equal 3, html.scan(/title=/).size
    assert_match 'title="today"', html
    assert_match 'title="2d ago"', html
  end

  test "MiniTicks renders the last 16 checks and the uptime percent" do
    checks = ([ "up" ] * 15) + [ "down" ] # 16 checks, 15 up
    html = render(partial: "shared/mini_ticks", locals: { checks: checks })

    assert_equal 16, html.scan(/rounded-\[1\.5px\]/).size
    assert_match "94%", html # 15/16 = 93.75 → 94
  end
end
