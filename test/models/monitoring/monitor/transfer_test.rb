require "test_helper"

# Moving a monitor between two of the user's projects (projects.md §6, §12-I).
# Manual-only: a gem monitor belongs to whichever project its API key syncs into,
# so it's not movable here. A target collision on (project_id, registration_key)
# is a clean rejection, never a 500.
class Monitoring::Monitor::TransferTest < ActiveSupport::TestCase
  setup do
    @alice = users(:alice)
    @source = @alice.projects.sole
    @target = @alice.projects.create!(name: "Second app")
  end

  def build_manual(name: "Manual job")
    @source.monitors.create!(name:, expected_interval_seconds: 3600, grace_period_seconds: 300, source: "manual")
  end

  test "moves a manual monitor into the target project" do
    monitor = build_manual
    result = monitor.transfer_to(@target)

    assert result.ok?
    assert_nil result.error
    assert_equal @target.id, monitor.reload.project_id
  end

  test "refuses to move a gem monitor" do
    gem_monitor = monitors(:gem_synced)
    result = gem_monitor.transfer_to(@target)

    refute result.ok?
    assert_equal :not_manual, result.error
    assert_equal @source.id, gem_monitor.reload.project_id # unchanged
  end

  test "moving to the project it already lives in is a no-op success" do
    monitor = build_manual
    result = monitor.transfer_to(@source)

    assert result.ok?
    assert_equal @source.id, monitor.reload.project_id
  end

  test "rejects a registration_key collision in the target rather than raising" do
    # A manual monitor normally has no registration_key, but guard the edge: if the
    # target already holds the same key, the DB's partial unique index would raise —
    # we surface a clean error instead of a 500.
    @target.monitors.create!(name: "Existing", expected_interval_seconds: 3600,
      grace_period_seconds: 300, source: "manual", registration_key: "shared_key")
    monitor = @source.monitors.create!(name: "Clashing", expected_interval_seconds: 3600,
      grace_period_seconds: 300, source: "manual", registration_key: "shared_key")

    result = monitor.transfer_to(@target)

    refute result.ok?
    assert_equal :collision, result.error
    assert_equal @source.id, monitor.reload.project_id # unchanged
  end
end
