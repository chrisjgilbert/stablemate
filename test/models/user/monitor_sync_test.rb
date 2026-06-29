require "test_helper"

class User::MonitorSyncTest < ActiveSupport::TestCase
  setup { @user = users(:bob) } # bob owns exactly one fixture monitor

  def entry(key, name: nil, interval: 3600, grace: 300)
    { registration_key: key, name: name || key,
      expected_interval_seconds: interval, grace_period_seconds: grace }
  end

  test "new registration keys create gem/pending monitors" do
    result = @user.sync_monitors(app: "my-app", entries: [ entry("daily_digest") ])

    monitor = result[:registered].first
    assert_equal "gem", monitor.source
    assert_equal "pending", monitor.status
    assert_equal "daily_digest", monitor.registration_key
    assert monitor.ping_token.present?
    assert_empty result[:skipped]
  end

  test "name defaults to the registration key when absent" do
    result = @user.sync_monitors(entries: [
      { registration_key: "cleanup", expected_interval_seconds: 3600, grace_period_seconds: 300 }
    ])
    assert_equal "cleanup", result[:registered].first.name
  end

  test "re-syncing is idempotent and updates rather than duplicating" do
    @user.sync_monitors(entries: [ entry("daily_digest", name: "First", interval: 3600) ])

    assert_no_difference -> { @user.monitors.count } do
      @user.sync_monitors(entries: [ entry("daily_digest", name: "Renamed", interval: 7200) ])
    end

    monitor = @user.monitors.find_by(registration_key: "daily_digest")
    assert_equal "Renamed", monitor.name
    assert_equal 7200, monitor.expected_interval_seconds
  end

  test "cap overflow registers up to the limit and skips the rest, still succeeds" do
    # bob has 1 monitor; cap is 5 -> 4 slots remain. Sync 6 new keys.
    keys = %w[a b c d e f]
    result = @user.sync_monitors(entries: keys.map { |k| entry(k) })

    assert_equal Stablemate::MAX_MONITORS_PER_USER, @user.monitors.count
    assert_equal 4, result[:registered].size
    assert_equal 2, result[:skipped].size
    assert_equal %w[e f], result[:skipped].map { |s| s[:registration_key] }
    assert_equal [ "limit_reached" ], result[:skipped].map { |s| s[:reason] }.uniq
  end

  test "updates to existing monitors succeed even at the cap" do
    # Fill bob to the cap with gem monitors.
    @user.sync_monitors(entries: (1..4).map { |i| entry("k#{i}") })
    assert @user.reload.at_monitor_cap?

    result = @user.sync_monitors(entries: [ entry("k1", name: "Updated", interval: 600) ])

    assert_empty result[:skipped]
    assert_equal "Updated", @user.monitors.find_by(registration_key: "k1").name
  end

  test "monitors absent from the payload are left untouched (no auto-delete)" do
    @user.sync_monitors(entries: [ entry("keep") ])
    before = @user.monitors.count

    @user.sync_monitors(entries: [ entry("other") ])

    assert_equal before + 1, @user.monitors.count
    assert @user.monitors.exists?(registration_key: "keep")
  end

  test "entries without a registration_key are ignored" do
    assert_no_difference -> { @user.monitors.count } do
      result = @user.sync_monitors(entries: [ { name: "no key" } ])
      assert_empty result[:registered]
    end
  end

  test "an invalid entry is skipped, not raised, and valid entries still register" do
    result = nil
    assert_nothing_raised do
      result = @user.sync_monitors(entries: [
        entry("good"),
        { registration_key: "bad", name: "Bad", expected_interval_seconds: 0, grace_period_seconds: 5 }
      ])
    end

    assert_equal [ "good" ], result[:registered].map(&:registration_key)
    assert_equal [ { registration_key: "bad", reason: "invalid" } ], result[:skipped]
    assert @user.monitors.exists?(registration_key: "good")
    refute @user.monitors.exists?(registration_key: "bad")
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
    @user.monitors.create!(
      registration_key: "racey", name: "Original", expected_interval_seconds: 3600,
      grace_period_seconds: 300, source: "gem", status: "pending"
    )

    op = User::MonitorSync::Operation.new(@user)
    racing_entry = User::MonitorSync::Operation::Entry.from(
      entry("racey", name: "Updated", interval: 7200)
    )
    registered = []
    skipped = []

    assert_nothing_raised do
      op.send(:persist_create, racing_entry, registered, skipped)
    end

    assert_empty skipped
    assert_equal [ "racey" ], registered.map(&:registration_key)
    assert_equal "Updated", @user.monitors.find_by(registration_key: "racey").name
    assert_equal 1, @user.monitors.where(registration_key: "racey").count
  end

  test "an entry that is both invalid and over cap reports invalid, not limit_reached" do
    @user.sync_monitors(entries: (1..4).map { |i| entry("k#{i}") })
    assert @user.reload.at_monitor_cap?

    result = @user.sync_monitors(entries: [
      { registration_key: "bad", name: "Bad", expected_interval_seconds: 0, grace_period_seconds: 5 }
    ])

    assert_equal [ { registration_key: "bad", reason: "invalid" } ], result[:skipped]
    refute @user.monitors.exists?(registration_key: "bad")
  end

  test "an invalid update is skipped without wiping the existing monitor" do
    @user.sync_monitors(entries: [ entry("keep", interval: 3600) ])
    result = @user.sync_monitors(entries: [
      { registration_key: "keep", name: "Keep", expected_interval_seconds: -1, grace_period_seconds: 5 }
    ])

    assert_equal "invalid", result[:skipped].first[:reason]
    assert_equal 3600, @user.monitors.find_by(registration_key: "keep").expected_interval_seconds
  end

  # Caps OFF (issue #16): with no cap configured, the gem sync never skips for
  # limit_reached — every well-formed new key registers, however many there are.
  test "with the cap OFF, sync never skips for limit_reached" do
    stub_const(Stablemate, :MAX_MONITORS_PER_USER, 0) do
      keys = %w[a b c d e f g h] # bob already owns 1 fixture monitor -> 9 total
      result = @user.sync_monitors(entries: keys.map { |k| entry(k) })

      assert_equal keys.size, result[:registered].size
      assert_empty result[:skipped]
      assert_equal keys.size + 1, @user.monitors.count
    end
  end

  test "cannot mass-assign protected attributes through the payload" do
    result = @user.sync_monitors(entries: [
      { registration_key: "evil", name: "Evil", expected_interval_seconds: 60,
        grace_period_seconds: 5, source: "manual", status: "up",
        ping_token: "attacker_chosen_token", user_id: users(:alice).id }
    ])
    monitor = result[:registered].first

    assert_equal "gem", monitor.source
    assert_equal "pending", monitor.status
    assert_not_equal "attacker_chosen_token", monitor.ping_token
    assert_equal @user, monitor.user
  end
end
