require "application_system_test_case"

# Browser-driven move-a-monitor flow (projects.md §6): a MANUAL monitor moves from
# one project to another via the Turbo form on its detail page and shows up under
# the target; a gem monitor offers no move control (it's tied to its API key,
# §12-I). CLAUDE.md: every user-facing flow ships a browser-driven system test.
class MonitorMoveTest < ApplicationSystemTestCase
  setup do
    @alice = users(:alice)
    @source = @alice.projects.sole
    @target = @alice.projects.create!(name: "Payments")
    @monitor = @source.monitors.create!(name: "Manual heartbeat",
      expected_interval_seconds: 3600, grace_period_seconds: 300, source: "manual")
    sign_in @alice
  end

  test "moving a manual monitor lands it under the target project" do
    visit monitor_path(@monitor)

    within "[data-testid='monitor-project-card']" do
      select "Payments", from: "project_id" # Rails-generated select id
      click_on "Move"
    end

    # Redirects to the target project's show page, where the monitor now lives.
    assert_current_path project_path(@target)
    assert_text "Manual heartbeat"
    assert_equal @target.id, @monitor.reload.project_id
  end

  test "a gem monitor offers no move control" do
    gem_monitor = monitors(:gem_synced)
    visit monitor_path(gem_monitor)

    within "[data-testid='monitor-project-card']" do
      assert_selector "[data-testid='move-gem-note']"
      assert_no_button "Move"
      assert_no_selector "select[aria-label='Move to project']"
    end
  end
end
