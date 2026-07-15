require "test_helper"

class Monitoring::MonitorTest < ActiveSupport::TestCase
  # Use bob (no fixture monitors) so cap-of-5 doesn't trip these create tests.
  setup { @user = users(:bob); @project = @user.projects.sole; @project.monitors.delete_all }

  # Valid interval/grace are required by the model — supply them everywhere.
  ATTRS = { expected_interval_seconds: 3600, grace_period_seconds: 300 }.freeze

  # Scenario 8 — ping_token is auto-generated on create.
  test "generates a ping_token on create when none is given" do
    monitor = @project.monitors.create!(name: "New monitor", **ATTRS)

    assert monitor.ping_token.present?
    assert_operator monitor.ping_token.length, :>=, 32
  end

  test "generated ping_tokens are unique across monitors" do
    a = @project.monitors.create!(name: "A", **ATTRS)
    b = @project.monitors.create!(name: "B", **ATTRS)

    assert_not_equal a.ping_token, b.ping_token
  end

  test "keeps an explicitly provided ping_token" do
    monitor = @project.monitors.create!(name: "Explicit", ping_token: "my-explicit-token-1234567890abcd", **ATTRS)

    assert_equal "my-explicit-token-1234567890abcd", monitor.ping_token
  end

  # Scenario 9 — two monitors cannot share a ping_token (model + db).
  test "ping_token uniqueness is enforced at the model level" do
    existing = monitors(:up)
    dup = @project.monitors.build(name: "Dup", ping_token: existing.ping_token)

    assert_not dup.valid?
    assert_includes dup.errors[:ping_token], "has already been taken"
  end

  test "ping_token uniqueness is enforced at the database level" do
    existing = monitors(:up)
    dup = @project.monitors.build(name: "Dup", ping_token: existing.ping_token)

    # Bypass the model validation to prove the DB unique index is the backstop.
    assert_raises(ActiveRecord::RecordNotUnique) do
      dup.save!(validate: false)
    end
  end

  test "rotate_ping_token! replaces the token with a new unique value" do
    monitor = @project.monitors.create!(name: "Rotate me", **ATTRS)
    original = monitor.ping_token

    monitor.rotate_ping_token!

    assert_not_equal original, monitor.ping_token
    assert monitor.ping_token.present?
  end

  # Scenario 7 — a new manual monitor stores seconds, gets a token, is pending/manual.
  test "a created monitor stores interval/grace in seconds, is manual and pending" do
    monitor = @project.monitors.create!(name: "Fresh", expected_interval_seconds: 3600, grace_period_seconds: 300, source: "manual")

    assert_equal 3600, monitor.expected_interval_seconds
    assert_equal "manual", monitor.source
    assert_equal "pending", monitor.status
    assert monitor.ping_token.present?
  end

  # Scenario 8 — a user at the cap cannot create another monitor.
  test "a user at the monitor cap cannot create another monitor" do
    Stablemate::MAX_MONITORS_PER_USER.times { |i| @project.monitors.create!(name: "M#{i}", **ATTRS) }

    sixth = @project.monitors.build(name: "Over", **ATTRS)
    refute sixth.valid?
    assert sixth.errors[:base].any? { |m| m.include?(@user.monitor_limit.to_s) }
  end

  # Scenario 9 — paused monitors still count toward the cap.
  test "paused monitors count toward the cap" do
    Stablemate::MAX_MONITORS_PER_USER.times { |i| @project.monitors.create!(name: "M#{i}", **ATTRS) }
    @user.monitors.first.pause!

    refute @project.monitors.build(name: "Over", **ATTRS).valid?
  end

  # Caps OFF (issue #16): with no cap configured, creating past the old limit is
  # allowed — the within_monitor_cap validation never fires.
  test "with the cap OFF, a user can create monitors past the old limit" do
    stub_const(Stablemate, :MAX_MONITORS_PER_USER, 0) do
      6.times { |i| @project.monitors.create!(name: "M#{i}", **ATTRS) }

      sixth_plus = @project.monitors.build(name: "Seventh", **ATTRS)
      assert sixth_plus.valid?
      assert sixth_plus.save
      assert_equal 7, @user.monitors.count
    end
  end

  # Scenario 11 — editing an existing monitor at the cap is allowed.
  test "editing an existing monitor when at the cap succeeds" do
    Stablemate::MAX_MONITORS_PER_USER.times { |i| @project.monitors.create!(name: "M#{i}", **ATTRS) }
    monitor = @user.monitors.first

    assert monitor.update(name: "Renamed at cap")
    assert_equal "Renamed at cap", monitor.reload.name
  end

  # Scenario 13 — deleting a monitor cascades to pings/incidents/notifications.
  test "deleting a monitor destroys dependent pings, incidents, and notifications" do
    monitor = @project.monitors.create!(name: "Doomed", **ATTRS)
    monitor.update!(status: "up", last_ping_at: 1.hour.ago, next_due_at: 1.hour.ago)
    monitor.flag_missed!
    monitor.ping_events.create!(received_at: Time.current)

    assert_operator monitor.ping_events.count, :>, 0
    assert_operator monitor.incidents.count, :>, 0
    assert_operator monitor.notifications.count, :>, 0

    monitor_id = monitor.id
    monitor.destroy

    assert_empty PingEvent.where(monitor_id: monitor_id)
    assert_empty Incident.where(monitor_id: monitor_id)
    assert_empty Notification.where(monitor_id: monitor_id)
  end
end
