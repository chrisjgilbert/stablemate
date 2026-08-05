require "test_helper"

class Monitoring::MonitorTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  # carol owns no monitors, so the cap assertions here count only what they create.
  setup { @user = users(:carol); @project = @user.projects.sole }

  # Valid interval/grace are required by the model — supply them everywhere.
  ATTRS = { expected_interval_seconds: 3600, grace_period_seconds: 300 }.freeze

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

  test "a created monitor stores interval/grace in seconds, is manual and pending" do
    monitor = @project.monitors.create!(name: "Fresh", expected_interval_seconds: 3600, grace_period_seconds: 300, source: "manual")

    assert_equal 3600, monitor.expected_interval_seconds
    assert_equal "manual", monitor.source
    assert_equal "pending", monitor.status
    assert monitor.ping_token.present?
  end

  # awaiting_setup? gates the detail page's full ping-setup card: only a manual,
  # never-pinged, not-suspended monitor still needs hand-wiring.
  test "awaiting_setup? is true only for a manual, never-pinged, unsuspended monitor" do
    monitor = @project.monitors.create!(name: "Fresh", **ATTRS)
    assert monitor.awaiting_setup?

    monitor.last_ping_at = Time.current
    assert_not monitor.awaiting_setup?, "pinged monitors are wired up"

    monitor.last_ping_at = nil
    monitor.status = "suspended"
    assert_not monitor.awaiting_setup?, "a ping can't reactivate a suspended monitor"

    assert_not @project.monitors.create!(name: "Synced", source: "gem", **ATTRS).awaiting_setup?,
      "gem monitors get their URL from the API sync"
  end

  test "a user at the monitor cap cannot create another monitor" do
    Stablemate::MAX_MONITORS_PER_USER.times { |i| @project.monitors.create!(name: "M#{i}", **ATTRS) }

    sixth = @project.monitors.build(name: "Over", **ATTRS)
    refute sixth.valid?
    assert sixth.errors[:base].any? { |m| m.include?(@user.monitor_limit.to_s) }
  end

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

  test "editing an existing monitor when at the cap succeeds" do
    Stablemate::MAX_MONITORS_PER_USER.times { |i| @project.monitors.create!(name: "M#{i}", **ATTRS) }
    monitor = @user.monitors.first

    assert monitor.update(name: "Renamed at cap")
    assert_equal "Renamed at cap", monitor.reload.name
  end

  # F10's sibling. The alert dispatch waits for the caller's transaction to
  # commit; the Turbo broadcast did not, and the webhook / choose-N reactivation
  # paths reach it from inside ProcessedEvent.record_once's transaction. Solid
  # Queue is a SEPARATE database, so the broadcast job could be claimed by a
  # worker that renders the monitor as it was BEFORE the change — a badge stuck
  # showing the old status — and a rollback (the designed Stripe-retry path) left
  # an orphan job for a change that never happened. Cheaper to fix than to reason
  # about.
  test "the status broadcast is enqueued only once the surrounding transaction commits" do
    monitor = @project.monitors.create!(name: "Broadcast", **ATTRS)

    assert_enqueued_jobs 2, only: Turbo::Streams::ActionBroadcastJob do
      ActiveRecord::Base.transaction do
        monitor.broadcast_status_update

        # Nothing may be visible to a worker (separate queue DB) before commit.
        assert_no_enqueued_jobs only: Turbo::Streams::ActionBroadcastJob
      end
    end
  end

  test "a rolled-back transaction broadcasts nothing" do
    monitor = @project.monitors.create!(name: "Broadcast", **ATTRS)

    assert_no_enqueued_jobs only: Turbo::Streams::ActionBroadcastJob do
      ActiveRecord::Base.transaction do
        monitor.broadcast_status_update
        raise ActiveRecord::Rollback
      end
    end
  end

  # The ping paths broadcast with no transaction open (they dispatch outside their
  # own with_lock), and must stay immediate.
  test "with no surrounding transaction the broadcast happens immediately" do
    monitor = @project.monitors.create!(name: "Broadcast", **ATTRS)

    assert_enqueued_jobs 2, only: Turbo::Streams::ActionBroadcastJob do
      monitor.broadcast_status_update
    end
  end

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
