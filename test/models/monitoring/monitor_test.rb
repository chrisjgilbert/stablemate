require "test_helper"

class Monitoring::MonitorTest < ActiveSupport::TestCase
  setup { @user = users(:alice) }

  # Scenario 8 — ping_token is auto-generated on create.
  test "generates a ping_token on create when none is given" do
    monitor = @user.monitors.create!(name: "New monitor")

    assert monitor.ping_token.present?
    assert_operator monitor.ping_token.length, :>=, 32
  end

  test "generated ping_tokens are unique across monitors" do
    a = @user.monitors.create!(name: "A")
    b = @user.monitors.create!(name: "B")

    assert_not_equal a.ping_token, b.ping_token
  end

  test "keeps an explicitly provided ping_token" do
    monitor = @user.monitors.create!(name: "Explicit", ping_token: "my-explicit-token-1234567890abcd")

    assert_equal "my-explicit-token-1234567890abcd", monitor.ping_token
  end

  # Scenario 9 — two monitors cannot share a ping_token (model + db).
  test "ping_token uniqueness is enforced at the model level" do
    existing = monitors(:up)
    dup = @user.monitors.build(name: "Dup", ping_token: existing.ping_token)

    assert_not dup.valid?
    assert_includes dup.errors[:ping_token], "has already been taken"
  end

  test "ping_token uniqueness is enforced at the database level" do
    existing = monitors(:up)
    dup = @user.monitors.build(name: "Dup", ping_token: existing.ping_token)

    # Bypass the model validation to prove the DB unique index is the backstop.
    assert_raises(ActiveRecord::RecordNotUnique) do
      dup.save!(validate: false)
    end
  end

  test "rotate_ping_token! replaces the token with a new unique value" do
    monitor = @user.monitors.create!(name: "Rotate me")
    original = monitor.ping_token

    monitor.rotate_ping_token!

    assert_not_equal original, monitor.ping_token
    assert monitor.ping_token.present?
  end
end
