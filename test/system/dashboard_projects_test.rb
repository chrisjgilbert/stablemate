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

  # (§3) the first-run card creates the first project INLINE — no extra page load.
  test "the first-run card creates the first project inline" do
    bob = users(:bob)
    bob.projects.destroy_all

    sign_in bob
    within "[data-testid='create-first-project']" do
      fill_in "Project name", with: "Inline app"
      click_on "Create project"
    end

    # Created and now shown (landed on the project's show page).
    assert_text "Inline app"
    assert bob.projects.exists?(name: "Inline app")
  end

  # (§2) a project with zero active monitors still renders, with an inline hint —
  # it must not vanish, and the account-wide empty state must not double up.
  test "a project with no monitors shows an inline hint on the dashboard" do
    project = @alice.projects.sole
    project.monitors.delete_all

    sign_in @alice
    within find("section[data-testid='project-group']", text: project.name) do
      assert_text "No monitors yet"
    end
    # No doubled account-wide empty state — the per-group hint covers it.
    assert_no_selector "[data-testid='empty-state']"
  end

  # (§2) each group header links to new-monitor pre-selecting that project.
  test "a project group header links to new monitor pre-selecting that project" do
    first = @alice.projects.sole
    first.monitors.delete_all
    first.monitors.create!(name: "Alpha job", **ATTRS)
    target = @alice.projects.create!(name: "Second service")
    target.monitors.create!(name: "Beta job", **ATTRS)

    sign_in @alice
    within find("section[data-testid='project-group']", text: "Second service") do
      click_on "New monitor"
    end

    # The new-monitor form pre-selects the project we launched from.
    assert_selector "option[selected]", text: "Second service"
  end

  # (§8) at the monitor cap the cap-skip banner offers an Upgrade-to-Pro link.
  test "the cap-skip banner links to upgrade when at the monitor cap" do
    with_billing_enabled do
      project = @alice.projects.sole
      project.monitors.delete_all
      Stablemate::FREE_PLAN_MONITOR_LIMIT.times { |i| project.monitors.create!(name: "M#{i}", **ATTRS) }
      assert @alice.reload.at_monitor_cap?

      sign_in @alice
      within "[data-testid='cap-skip-banner']" do
        assert_link "Upgrade to Pro", href: billing_subscription_path
      end
    end
  end
end
