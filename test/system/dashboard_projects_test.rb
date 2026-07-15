require "application_system_test_case"

# Browser-driven dashboard/onboarding flows for projects (projects.md §6, §4.4):
# the grouped-by-project dashboard, creating a monitor into a chosen project via
# the selector, and the zero-project first run that routes through project
# creation. CLAUDE.md: every user-facing flow ships a browser-driven system test.
class DashboardProjectsTest < ApplicationSystemTestCase
  ATTRS = { expected_interval_seconds: 3600, grace_period_seconds: 300 }.freeze

  setup { @alice = users(:alice) }

  # (b) the dashboard groups monitor rows under per-project section headers.
  test "the dashboard groups monitors under per-project headers" do
    first = @alice.projects.sole
    first.monitors.delete_all
    first.monitors.create!(name: "Alpha job", **ATTRS)
    second = @alice.projects.create!(name: "Second service")
    second.monitors.create!(name: "Beta job", **ATTRS)

    sign_in @alice
    assert_selector "[data-testid='project-group']", count: 2
    assert_text "Alpha job"
    assert_text "Beta job"

    # The Beta row lives under the Second-service section, not the other one.
    within find("section[data-testid='project-group']", text: "Second service") do
      assert_text "Beta job"
      assert_no_text "Alpha job"
    end
  end

  # (c) create a monitor into a chosen project via the form's project selector.
  test "creating a monitor into a chosen project via the selector" do
    @alice.projects.sole.monitors.delete_all
    target = @alice.projects.create!(name: "Target service")

    sign_in @alice
    first(:link, "New monitor").click

    select "Target service", from: "Project"
    fill_in "Name", with: "Chosen job"
    find("select[aria-label='Expected interval preset']").select("Hourly")
    find("select[aria-label='Grace period preset']").select("5 minutes")
    click_on "Create monitor"

    assert_text "Chosen job"
    assert_equal target, Monitoring::Monitor.find_by(name: "Chosen job").project
  end

  # (e) a brand-new user with no project sees the create-first-project empty state
  # and is routed into project creation, then returned to monitor creation.
  test "a zero-project user is onboarded through project creation" do
    bob = users(:bob)
    bob.projects.destroy_all

    sign_in bob
    assert_selector "[data-testid='first-project-empty-state']"
    assert_text "Create your first project"

    # "Add a monitor" must route through project creation first.
    visit new_monitor_path
    assert_current_path new_project_path, ignore_query: true

    fill_in "Project name", with: "Fresh app"
    click_on "Create project"

    # Returned to monitor creation, with the new project available to pick.
    assert_current_path new_monitor_path
    assert_text "Fresh app"
  end
end
