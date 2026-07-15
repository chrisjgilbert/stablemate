require "application_system_test_case"

# Browser-driven per-project API-key flow (projects.md §6): from a project's page,
# generate a project-scoped key and see the full sm_live_… token exactly once in
# the shown-once modal (Copy + amber warning), then revoke it. Keys live under the
# project now, not a standalone settings screen. CLAUDE.md: every user-facing flow
# ships a browser-driven system test.
class ApiKeysTest < ApplicationSystemTestCase
  setup do
    @alice = users(:alice)
    @project = @alice.projects.sole
    sign_in @alice
  end

  # S13 — empty state on the project page.
  test "a project with no keys offers to generate one" do
    visit project_path(@project)
    assert_selector "[data-testid='api-keys-empty']"
    assert_text "No API keys yet"
    assert_button "Generate key"
  end

  # S11 — generate key: modal shows the full sm_live_… once + Copy + amber warning;
  # after dismissing, only the masked form remains.
  test "generating a key shows the full key once then masks it" do
    visit project_path(@project)
    click_on "Generate key"

    assert_selector "[data-testid='api-key-modal']"
    assert_selector "[data-testid='api-key-warning']", text: "won't see it again"
    full_key = find("[data-testid='api-key-modal'] input[aria-label='API key']").value
    assert_match(/\Asm_live_[A-Za-z0-9]{32}\z/, full_key)
    assert_button "Copy"

    # Dismiss the modal -> the list shows only the masked form, never the full key.
    click_on "Done"
    assert_no_selector "[data-testid='api-key-modal']"
    assert_no_text full_key
    assert_text "sm_live_••••#{full_key.last(4)}"
  end

  # S12 — revoke: the key disappears from the table.
  test "revoking a key removes it from the project's list" do
    key, = ApiKey.issue(project: @project, name: "CI")
    visit project_path(@project)
    assert_text key.masked

    accept_confirm { click_on "Revoke" }
    assert_no_text key.masked
    assert_selector "[data-testid='api-keys-empty']"
  end
end
