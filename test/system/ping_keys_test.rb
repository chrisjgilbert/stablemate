require "application_system_test_case"

# Browser-driven per-project ping-key flow (v1-scope §4). The ping key is the
# credential the gem puts on every check-in, so the whole of its lifecycle —
# issue, see once, masked forever after, revoke — has to work in a real browser.
# CLAUDE.md: every user-facing flow ships a browser-driven system test.
class PingKeysTest < ApplicationSystemTestCase
  setup do
    @alice = users(:alice)
    @project = @alice.projects.sole
    sign_in @alice
  end

  test "a project with no ping keys offers to generate one" do
    visit project_path(@project)
    assert_selector "[data-testid='ping-keys-empty']"
    assert_text "No ping keys yet"
    assert_button "Generate ping key"
  end

  # Shown once is the whole storage design: only a SHA-256 digest and the last 4
  # characters are persisted, so nothing can ever re-display the raw key.
  test "generating a ping key shows the full key once then masks it" do
    visit project_path(@project)
    click_on "Generate ping key"

    assert_selector "[data-testid='ping-key-modal']"
    assert_selector "[data-testid='ping-key-warning']", text: "won't see it again"
    full_key = find("[data-testid='ping-key-modal'] input[aria-label='Ping key']").value
    assert_match(/\Asm_ping_[A-Za-z0-9]{32}\z/, full_key)
    assert_button "Copy"

    click_on "Done"
    assert_no_selector "[data-testid='ping-key-modal']"
    assert_no_text full_key
    assert_text "sm_ping_••••#{full_key.last(4)}"
  end

  test "revoking a ping key removes it from the project's list" do
    key, = PingKey.issue(project: @project, name: "Production")
    visit project_path(@project)
    assert_text key.masked

    within "[data-testid='project-ping-keys']" do
      accept_confirm { click_on "Revoke" }
    end
    assert_no_text key.masked
    assert_selector "[data-testid='ping-keys-empty']"
  end

  # Rotation is add-before-remove: issue the second, deploy it, watch the first
  # stop being used, revoke it. Nothing breaks in between, and that is what makes
  # shown-once affordable.
  test "a second key can be generated while the first is still live" do
    first, = PingKey.issue(project: @project, name: "Production")
    visit project_path(@project)

    click_on "Generate ping key"
    click_on "Done"

    assert_text first.masked
    assert_selector "[data-testid='project-ping-keys'] tbody tr", count: 2
  end

  # The two credentials are managed side by side and must stay legible as two:
  # one rides every check-in, the other registers monitors.
  test "the project page lists ping keys and API keys separately" do
    PingKey.issue(project: @project, name: "Production")
    ApiKey.issue(project: @project, name: "CI")
    visit project_path(@project)

    within("[data-testid='project-ping-keys']") { assert_text "sm_ping_••••" }
    within("[data-testid='project-api-keys']") { assert_text "sm_live_••••" }
  end
end
