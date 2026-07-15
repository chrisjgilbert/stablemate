require "test_helper"

# Ported from User::MonitorSyncTest to project scope (projects.md §4.3 / §10). The
# upsert now keys on (project, registration_key) and the cap budget stays PER-USER
# (the row lock stays on the user). Every original scenario carries over; new tests
# prove the collision fix, the per-user budget across projects, and the user lock.
class Project::MonitorSyncTest < ActiveSupport::TestCase
  # bob owns exactly one fixture monitor, in his one fixture project.
  setup do
    @user = users(:bob)
    @project = @user.projects.sole
  end

  def entry(key, name: nil, interval: 3600, grace: 300)
    { registration_key: key, name: name || key,
      expected_interval_seconds: interval, grace_period_seconds: grace }
  end

  test "new registration keys create gem/pending monitors" do
    result = @project.sync_monitors(app: "my-app", entries: [ entry("daily_digest") ])

    monitor = result[:registered].first
    assert_equal "gem", monitor.source
    assert_equal "pending", monitor.status
    assert_equal "daily_digest", monitor.registration_key
    assert monitor.ping_token.present?
    assert_empty result[:skipped]
  end

  test "name defaults to the registration key when absent" do
    result = @project.sync_monitors(entries: [
      { registration_key: "cleanup", expected_interval_seconds: 3600, grace_period_seconds: 300 }
    ])
    assert_equal "cleanup", result[:registered].first.name
  end

  test "re-syncing is idempotent and updates rather than duplicating" do
    @project.sync_monitors(entries: [ entry("daily_digest", name: "First", interval: 3600) ])

    assert_no_difference -> { @project.monitors.count } do
      @project.sync_monitors(entries: [ entry("daily_digest", name: "Renamed", interval: 7200) ])
    end

    monitor = @project.monitors.find_by(registration_key: "daily_digest")
    assert_equal "Renamed", monitor.name
    assert_equal 7200, monitor.expected_interval_seconds
  end

  test "cap overflow registers up to the limit and skips the rest, still succeeds" do
    # bob has 1 monitor; cap is 5 -> 4 slots remain. Sync 6 new keys.
    keys = %w[a b c d e f]
    result = @project.sync_monitors(entries: keys.map { |k| entry(k) })

    assert_equal Stablemate::MAX_MONITORS_PER_USER, @user.monitors.count
    assert_equal 4, result[:registered].size
    assert_equal 2, result[:skipped].size
    assert_equal %w[e f], result[:skipped].map { |s| s[:registration_key] }
    assert_equal [ "limit_reached" ], result[:skipped].map { |s| s[:reason] }.uniq
  end

  test "updates to existing monitors succeed even at the cap" do
    # Fill bob to the cap with gem monitors.
    @project.sync_monitors(entries: (1..4).map { |i| entry("k#{i}") })
    assert @user.reload.at_monitor_cap?

    result = @project.sync_monitors(entries: [ entry("k1", name: "Updated", interval: 600) ])

    assert_empty result[:skipped]
    assert_equal "Updated", @project.monitors.find_by(registration_key: "k1").name
  end

  test "monitors absent from the payload are left untouched (no auto-delete)" do
    @project.sync_monitors(entries: [ entry("keep") ])
    before = @project.monitors.count

    @project.sync_monitors(entries: [ entry("other") ])

    assert_equal before + 1, @project.monitors.count
    assert @project.monitors.exists?(registration_key: "keep")
  end

  test "entries without a registration_key are ignored" do
    assert_no_difference -> { @project.monitors.count } do
      result = @project.sync_monitors(entries: [ { name: "no key" } ])
      assert_empty result[:registered]
    end
  end

  test "an invalid entry is skipped, not raised, and valid entries still register" do
    result = nil
    assert_nothing_raised do
      result = @project.sync_monitors(entries: [
        entry("good"),
        { registration_key: "bad", name: "Bad", expected_interval_seconds: 0, grace_period_seconds: 5 }
      ])
    end

    assert_equal [ "good" ], result[:registered].map(&:registration_key)
    assert_equal [ { registration_key: "bad", reason: "invalid" } ], result[:skipped]
    assert @project.monitors.exists?(registration_key: "good")
    refute @project.monitors.exists?(registration_key: "bad")
  end

  test "a concurrent create of the same key (RecordNotUnique) is upserted, not raised" do
    # The race: a sibling boot process (another Puma worker / container running
    # the railtie's after_initialize sync) already inserted this key, but THIS
    # run's lookup ran before that insert landed, so it takes the create path and
    # the partial unique index raises RecordNotUnique. The operation must recover
    # by updating the now-existing row (idempotent), never 500.
    #
    # Drive persist_create directly against an already-existing key — that is
    # exactly the state the create path hits during the race — so the unique
    # index fires for real and the rescue's re-find + update runs.
    @project.monitors.create!(
      registration_key: "racey", name: "Original", expected_interval_seconds: 3600,
      grace_period_seconds: 300, source: "gem", status: "pending"
    )

    op = Project::MonitorSync.new(@project)
    racing_entry = Project::MonitorSync::Entry.from(
      entry("racey", name: "Updated", interval: 7200)
    )
    # persist_create accumulates into the operation's own ivars (seeded by #sync_monitors);
    # seed them directly for this white-box drive of the RecordNotUnique rescue path.
    %i[@registered @skipped @conflicts].each { |iv| op.instance_variable_set(iv, []) }

    assert_nothing_raised do
      op.send(:persist_create, racing_entry)
    end

    assert_empty op.instance_variable_get(:@skipped)
    assert_equal [ "racey" ], op.instance_variable_get(:@registered).map(&:registration_key)
    assert_equal "Updated", @project.monitors.find_by(registration_key: "racey").name
    assert_equal 1, @project.monitors.where(registration_key: "racey").count
  end

  test "an entry that is both invalid and over cap reports invalid, not limit_reached" do
    @project.sync_monitors(entries: (1..4).map { |i| entry("k#{i}") })
    assert @user.reload.at_monitor_cap?

    result = @project.sync_monitors(entries: [
      { registration_key: "bad", name: "Bad", expected_interval_seconds: 0, grace_period_seconds: 5 }
    ])

    assert_equal [ { registration_key: "bad", reason: "invalid" } ], result[:skipped]
    refute @project.monitors.exists?(registration_key: "bad")
  end

  test "an invalid update is skipped without wiping the existing monitor" do
    @project.sync_monitors(entries: [ entry("keep", interval: 3600) ])
    result = @project.sync_monitors(entries: [
      { registration_key: "keep", name: "Keep", expected_interval_seconds: -1, grace_period_seconds: 5 }
    ])

    assert_equal "invalid", result[:skipped].first[:reason]
    assert_equal 3600, @project.monitors.find_by(registration_key: "keep").expected_interval_seconds
  end

  # Caps OFF (issue #16): with no cap configured, the gem sync never skips for
  # limit_reached — every well-formed new key registers, however many there are.
  test "with the cap OFF, sync never skips for limit_reached" do
    stub_const(Stablemate, :MAX_MONITORS_PER_USER, 0) do
      keys = %w[a b c d e f g h] # bob already owns 1 fixture monitor -> 9 total
      result = @project.sync_monitors(entries: keys.map { |k| entry(k) })

      assert_equal keys.size, result[:registered].size
      assert_empty result[:skipped]
      assert_equal keys.size + 1, @project.monitors.count
    end
  end

  test "cannot mass-assign protected attributes through the payload" do
    other = @user.projects.create!(name: "Second app")
    result = @project.sync_monitors(entries: [
      { registration_key: "evil", name: "Evil", expected_interval_seconds: 60,
        grace_period_seconds: 5, source: "manual", status: "up",
        ping_token: "attacker_chosen_token", project_id: other.id, user_id: users(:alice).id }
    ])
    monitor = result[:registered].first

    assert_equal "gem", monitor.source
    assert_equal "pending", monitor.status
    assert_not_equal "attacker_chosen_token", monitor.ping_token
    # The operation controls scope, not the payload: the monitor lands in the
    # syncing project (and thus the syncing user), never the injected ones.
    assert_equal @project, monitor.project
    assert_equal @user, monitor.user
  end

  # --- New under Projects ---------------------------------------------------

  # The collision fix (§1): the SAME registration_key in two projects of one user
  # is two independent monitors — the silent-hijack bug the feature exists to kill.
  test "the same registration_key in two projects of one user coexists (no collision)" do
    other = @user.projects.create!(name: "Second app")

    @project.sync_monitors(entries: [ entry("daily_digest", name: "First") ])
    other.sync_monitors(entries: [ entry("daily_digest", name: "Second") ])

    assert_equal "First", @project.monitors.find_by(registration_key: "daily_digest").name
    assert_equal "Second", other.monitors.find_by(registration_key: "daily_digest").name
    assert_equal 2, @user.monitors.where(registration_key: "daily_digest").count
  end

  # The cap budget stays PER-USER across projects (§7): once the user is at the
  # cap via one project, another project's new keys come back limit_reached.
  test "the per-user cap is shared across projects" do
    other = @user.projects.create!(name: "Second app")
    # bob has 1 fixture monitor; cap 5 -> 4 slots. Fill them via @project.
    @project.sync_monitors(entries: (1..4).map { |i| entry("k#{i}") })
    assert @user.reload.at_monitor_cap?

    result = other.sync_monitors(entries: [ entry("newkey") ])
    assert_empty result[:registered]
    assert_equal [ "limit_reached" ], result[:skipped].map { |s| s[:reason] }
  end

  # The row lock stays on the USER, not the project (§4.3): the cap is per-user, so
  # concurrent syncs of different projects of one user must serialise on the shared
  # user row for the slot accounting to be atomic. Spy that with_lock is taken on
  # the user and never on the project.
  test "sync holds the row lock on the user, not the project" do
    locked = []
    user = @project.user # memoize the delegated instance the operation will reuse
    user.define_singleton_method(:with_lock) { |&blk| locked << :user; blk.call }
    @project.define_singleton_method(:with_lock) { |&blk| locked << :project; blk.call }

    @project.sync_monitors(entries: [ entry("x") ])

    assert_equal [ :user ], locked
  end

  # last_synced_app (§3.2 / §13-B3): the gem's app string is recorded on create,
  # and a later sync from a DIFFERENT app under the same project key is the
  # shared-key collision — reported under `conflicts` and the stored app advances.
  test "records last_synced_app and flags a diverging app under one project key" do
    create = @project.sync_monitors(app: "billing-app", entries: [ entry("heartbeat") ])
    assert_empty create[:conflicts]
    assert_equal "billing-app", @project.monitors.find_by(registration_key: "heartbeat").last_synced_app

    # Same key, different app under the same project = the collision to catch.
    diverge = @project.sync_monitors(app: "worker-app", entries: [ entry("heartbeat") ])
    assert_equal [ "heartbeat" ], diverge[:conflicts]
    assert_equal "worker-app", @project.monitors.find_by(registration_key: "heartbeat").last_synced_app

    # Re-syncing from the same app is not a conflict.
    same = @project.sync_monitors(app: "worker-app", entries: [ entry("heartbeat") ])
    assert_empty same[:conflicts]
  end
end
