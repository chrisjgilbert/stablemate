require "test_helper"

# The check-in credential (v1-scope §4). It mirrors ApiKey exactly except for the
# three deliberate differences §11 pins: the sm_ping_ prefix, the coarsened
# last_used_at write, and more than one live key per project.
class PingKeyTest < ActiveSupport::TestCase
  setup { @user = users(:alice); @project = @user.projects.sole }

  test "issue stores a SHA-256 digest and last4 and returns the raw key once" do
    ping_key, raw = PingKey.issue(project: @project, name: "Production")

    assert_match(/\Asm_ping_[A-Za-z0-9]{32}\z/, raw)
    assert_equal "Production", ping_key.name
    assert_equal raw.last(4), ping_key.token_last4
    assert_equal Digest::SHA256.hexdigest(raw), ping_key.token_digest

    # The raw token is not persisted anywhere in plaintext.
    refute_equal raw, ping_key.token_digest
    refute_includes ping_key.attributes.values.map(&:to_s), raw
  end

  test "masked form reveals only the last 4 characters" do
    ping_key, raw = PingKey.issue(project: @project, name: "Production")
    assert_equal "sm_ping_••••#{raw.last(4)}", ping_key.masked
  end

  test "authenticating resolves the right key and records first use" do
    ping_key, raw = PingKey.issue(project: @project, name: "Production")
    assert_nil ping_key.last_used_at

    found = freeze_time { PingKey.authenticating(raw) }
    assert_equal ping_key, found
    assert_not_nil found.last_used_at
  end

  test "authenticating returns nil for a wrong, blank, or nil token" do
    PingKey.issue(project: @project, name: "Production")

    assert_nil PingKey.authenticating("sm_ping_wrongwrongwrongwrongwrongwron")
    assert_nil PingKey.authenticating("")
    assert_nil PingKey.authenticating(nil)
  end

  # The separation is the whole reason ping_keys is its own table: a credential
  # resolved against the wrong table is a ping key authenticating the management
  # API (or vice versa). Neither lookup may ever see the other's rows.
  test "each credential authenticates only against its own table" do
    _api_key, api_raw = ApiKey.issue(project: @project, name: "CI")
    _ping_key, ping_raw = PingKey.issue(project: @project, name: "Production")

    assert_nil PingKey.authenticating(api_raw)
    assert_nil ApiKey.authenticating(ping_raw)
  end

  # §4's rotation procedure — issue the second, deploy it, watch the first stop
  # being used, revoke it — needs both live at once.
  test "a project may hold more than one live key" do
    first, first_raw = PingKey.issue(project: @project, name: "Production")
    second, second_raw = PingKey.issue(project: @project, name: "Production (new)")

    assert_equal first, PingKey.authenticating(first_raw)
    assert_equal second, PingKey.authenticating(second_raw)
  end

  # §5.2: on the check-in hot path an unconditional last_used_at write queues a
  # tenant's concurrent check-ins behind one row.
  test "last_used_at is written at most once per coarsening window" do
    ping_key, raw = PingKey.issue(project: @project, name: "Production")

    first_use = freeze_time { PingKey.authenticating(raw); ping_key.reload.last_used_at }

    travel_to(1.minute.from_now) { PingKey.authenticating(raw) }
    assert_equal first_use, ping_key.reload.last_used_at

    travel_to(6.minutes.from_now) { PingKey.authenticating(raw) }
    assert_operator ping_key.reload.last_used_at, :>, first_use
  end

  # §5.2 applies the same coarsening to ApiKey; its only reader is a "Last used"
  # column, so five-minute granularity costs nothing there either.
  test "the API key's last_used_at is coarsened the same way" do
    api_key, raw = ApiKey.issue(project: @project, name: "CI")

    first_use = freeze_time { ApiKey.authenticating(raw); api_key.reload.last_used_at }

    travel_to(1.minute.from_now) { ApiKey.authenticating(raw) }
    assert_equal first_use, api_key.reload.last_used_at

    travel_to(6.minutes.from_now) { ApiKey.authenticating(raw) }
    assert_operator api_key.reload.last_used_at, :>, first_use
  end

  test "revoking a key stops it authenticating" do
    ping_key, raw = PingKey.issue(project: @project, name: "Production")
    ping_key.destroy

    assert_nil PingKey.authenticating(raw)
  end

  test "destroying a project takes its ping keys with it" do
    project = @user.projects.create!(name: "Throwaway")
    PingKey.issue(project: project, name: "Production")

    assert_difference -> { PingKey.count }, -1 do
      project.destroy
    end
  end
end
