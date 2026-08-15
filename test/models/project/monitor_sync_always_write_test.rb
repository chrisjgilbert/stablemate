require "test_helper"

# v1-scope §3.1: with the edit form gone, `stablemate:sync` is the only writer of
# monitor config, so the "whose value is it?" question the `gem_may_write?`
# arbitration existed to answer has no second party. The sync writes every
# setting its payload carries.
#
# This file replaces the ten arbitration tests at monitor_sync_test.rb:279-431.
# Most of them asserted a refusal or the remembered columns and die with them;
# the survivor ("an untouched monitor still tracks recurring.yml") asserts
# exactly what always-write does and is kept here in its always-write form.
class Project::MonitorSyncAlwaysWriteTest < ActiveSupport::TestCase
  BASE = { registration_key: "nightly", name: "nightly",
           expected_interval_seconds: 3600, grace_period_seconds: 300 }.freeze

  setup do
    @project = users(:carol).projects.sole
    sync(BASE)
    @monitor = @project.monitors.sole
  end

  def sync(*entries, app: "my-app")
    @project.sync_monitors(app: app, entries: entries.map { |e| e.stringify_keys })
  end

  # --- The round trip ---------------------------------------------------------

  # §12: change an interval in the payload, sync, the monitor has it — then send
  # the original, sync, it's back. The second half is the half arbitration could
  # not do: under `gem_may_write?` the value only moved when the gem's remembered
  # value moved, so a revert was not always a revert.
  test "config round-trips through sync alone, in both directions" do
    sync(BASE.merge(expected_interval_seconds: 7200))
    assert_equal 7200, @monitor.reload.expected_interval_seconds

    sync(BASE)
    assert_equal 3600, @monitor.reload.expected_interval_seconds
  end

  # §3.1's recovery property, and the reason always-write is a security
  # improvement rather than a simplification: §4's headline attack writes a
  # 68-year interval, and any value changed OUTSIDE the sync path (a console
  # edit, or the pre-migration divergence the old KNOWN-LIMIT comment
  # documented) used to reject an unchanged payload on every sync, forever —
  # with the UI edit form as its only documented escape hatch. That hatch is
  # what §3.3 deletes.
  test "a value changed outside the sync path is restored by the very next sync" do
    @monitor.update_columns(expected_interval_seconds: 68.years.to_i, name: "poisoned")

    sync(BASE)

    @monitor.reload
    assert_equal 3600, @monitor.expected_interval_seconds
    assert_equal "nightly", @monitor.name
  end

  test "an unchanged payload re-synced twice is stable, not a ratchet" do
    2.times { sync(BASE) }

    @monitor.reload
    assert_equal 3600, @monitor.expected_interval_seconds
    assert_equal 300, @monitor.grace_period_seconds
    assert_equal "nightly", @monitor.name
  end

  # --- What "always" still does not mean --------------------------------------

  # "Writes unconditionally" read literally would write an ABSENT name as nil and
  # fail validation — and old gems send partial payloads, so this is the live
  # case, not a hypothetical. Absent stays untouched; that rule did not change.
  test "a field the payload omits is left alone, not nilled" do
    sync({ registration_key: "nightly", expected_interval_seconds: 900 })

    @monitor.reload
    assert_equal 900, @monitor.expected_interval_seconds
    assert_equal "nightly", @monitor.name        # never sent, never cleared
    assert_equal 300, @monitor.grace_period_seconds
  end

  # `schedule` is the ONE field where absent does not mean untouched. The gem
  # omits it exactly when there is no schedule — `c.monitors` entries send none
  # — so a task moved out of `recurring.yml` into `c.monitors` must lose its old
  # cron string. Leaving it would put a false sentence on the config panel,
  # which renders that string as where the config lives.
  test "a task that moves from a cron schedule to a bare interval loses the stale string" do
    sync(BASE.merge(schedule: "0 9 * * 1-5"))
    assert_equal "0 9 * * 1-5", @monitor.reload.schedule

    sync(BASE) # now declared in c.monitors: no schedule sent

    assert_nil @monitor.reload.schedule
  end

  test "a cron task that keeps its schedule keeps the string" do
    sync(BASE.merge(schedule: "0 9 * * 1-5"))
    sync(BASE.merge(schedule: "0 9 * * 1-5"))

    assert_equal "0 9 * * 1-5", @monitor.reload.schedule
  end

  # The arbitration is gone; the CROSS-APP guard that lived next to it is not.
  # `last_synced_app` looks like a fourth arbitration column and is a different
  # concept — dropping it with the other three would silently un-break two apps
  # syncing into one project.
  test "a second app syncing the same key is still reported as a conflict" do
    result = @project.sync_monitors(app: "other-app", entries: [ BASE.stringify_keys ])

    assert_includes result[:conflicts], "nightly"
    assert_equal "other-app", @monitor.reload.last_synced_app
  end

  # --- The columns and the branch are actually gone ---------------------------

  test "no arbitration column and no refusing branch survives" do
    %w[last_synced_name last_synced_expected_interval_seconds
       last_synced_grace_period_seconds].each do |column|
      assert_not Monitoring::Monitor.column_names.include?(column), "#{column} still exists"
    end
    assert_not defined?(Project::MonitorSync::GEM_SETTINGS)
  end
end
