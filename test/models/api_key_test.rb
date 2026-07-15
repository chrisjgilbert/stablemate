require "test_helper"

class ApiKeyTest < ActiveSupport::TestCase
  setup { @user = users(:alice); @project = @user.projects.sole }

  # Scenario 1 — issuance stores a digest + last4, returns the raw key once,
  # never persists plaintext.
  test "issue stores a SHA-256 digest and last4 and returns the raw key once" do
    api_key, raw = ApiKey.issue(project: @project, name: "CI")

    assert_match(/\Asm_live_[A-Za-z0-9]{32}\z/, raw)
    assert_equal "CI", api_key.name
    assert_equal raw.last(4), api_key.token_last4
    assert_equal Digest::SHA256.hexdigest(raw), api_key.token_digest

    # The raw token is not persisted anywhere in plaintext.
    refute_equal raw, api_key.token_digest
    refute_includes api_key.attributes.values.map(&:to_s), raw
  end

  test "masked form reveals only the last 4 characters" do
    api_key, raw = ApiKey.issue(project: @project, name: "CI")
    assert_equal "sm_live_••••#{raw.last(4)}", api_key.masked
  end

  # Scenario 2 — lookup by raw token matches via digest; a wrong token does not.
  test "authenticating resolves the right key and touches last_used_at" do
    api_key, raw = ApiKey.issue(project: @project, name: "CI")
    assert_nil api_key.last_used_at

    found = freeze_time { ApiKey.authenticating(raw) }
    assert_equal api_key, found
    assert_not_nil found.last_used_at
  end

  test "authenticating returns nil for a wrong, blank, or nil token" do
    ApiKey.issue(project: @project, name: "CI")

    assert_nil ApiKey.authenticating("sm_live_wrongwrongwrongwrongwrongwrong00")
    assert_nil ApiKey.authenticating("")
    assert_nil ApiKey.authenticating(nil)
  end

  test "digests are unique across keys" do
    ApiKey.issue(project: @project, name: "one")
    second, = ApiKey.issue(project: @project, name: "two")
    assert second.persisted?
  end
end
