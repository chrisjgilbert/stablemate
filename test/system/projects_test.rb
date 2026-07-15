require "application_system_test_case"

# Browser-driven Projects flows (projects.md §6): create a project (nav + list),
# and the strong type-the-name delete gate (button disabled until the typed value
# matches; deleting the last project drops to the create-first-project empty
# state). CLAUDE.md: every user-facing flow ships a browser-driven system test.
class ProjectsTest < ApplicationSystemTestCase
  setup do
    @alice = users(:alice)
  end

  # (a) create a project → it appears in the projects list, reached via the nav.
  test "creating a project shows it in the projects list" do
    sign_in @alice
    within("nav") { click_on "Projects" } # nav entry (disambiguate from breadcrumbs)

    click_on "New project"
    fill_in "Project name", with: "Billing service"
    click_on "Create project"

    # Lands on the new project's show page…
    assert_text "Billing service"
    # …and it's listed on the index.
    within("nav") { click_on "Projects" }
    assert_selector "h1", text: "Projects"
    assert_text "Billing service"
  end

  # (d) delete a project through the type-the-name gate: the delete button is
  # disabled until the typed value exactly matches, then it deletes. Alice has one
  # project, so deleting it drops to zero → the create-first-project empty state.
  test "deleting the last project needs the typed name and reveals the empty state" do
    project = @alice.projects.sole
    sign_in @alice
    visit edit_project_path(project)

    # Gate closed on load and while the typed name doesn't match.
    assert_button "Delete project", disabled: true
    fill_in "confirm_name", with: "not the name"
    assert_button "Delete project", disabled: true

    # Exact match opens the gate.
    fill_in "confirm_name", with: project.name
    assert_button "Delete project", disabled: false
    click_on "Delete project"

    # Deleted down to zero projects → the create-first-project empty state.
    assert_selector "[data-testid='first-project-empty-state']"
    assert_text "Create your first project"
    assert_not Project.exists?(project.id)
  end

  # (§7) the delete confirmation spells out the blast radius with counts.
  test "the delete confirmation states the blast radius with counts" do
    project = @alice.projects.sole
    ApiKey.issue(project: project, name: "CI")
    sign_in @alice
    visit edit_project_path(project)

    within "[data-testid='danger-zone']" do
      assert_text "#{project.monitors.count} monitor"
      assert_text "#{project.api_keys.count} API key"
    end
  end
end
