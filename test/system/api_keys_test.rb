require "application_system_test_case"

class ApiKeysTest < ApplicationSystemTestCase
  setup { sign_in users(:alice) }

  # S13 — empty state.
  test "empty state offers to generate the first key" do
    visit settings_api_keys_path
    assert_selector "[data-testid='api-keys-empty']"
    assert_text "No API keys yet"
    assert_button "Generate your first key"
  end

  # S11 — generate key: modal shows the full sm_live_… once + Copy + amber
  # warning; after dismissing, only the masked form remains.
  test "generating a key shows the full key once then masks it" do
    visit settings_api_keys_path
    click_on "Generate your first key"

    # Modal with the full key, copy button, and amber warning.
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
  test "revoking a key removes it from the table" do
    key, = ApiKey.issue(user: users(:alice), name: "CI")
    visit settings_api_keys_path
    assert_text key.masked

    accept_confirm { click_on "Revoke" }
    assert_no_text key.masked
    assert_selector "[data-testid='api-keys-empty']"
  end
end
