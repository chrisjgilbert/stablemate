require "test_helper"

# The upsert keys on (project, registration_key); the cap budget stays PER-USER
# (the row lock stays on the user).
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

  # M7 — one payload listing the same key twice used to be processed twice, so the
  # gem saw one job as two monitors (and a diverging app as two conflicts).
  test "a registration_key repeated in one payload yields one monitor" do
    result = @project.sync_monitors(app: "my-app", entries: [
      entry("daily_digest", name: "First", interval: 3600),
      entry("daily_digest", name: "Second", interval: 7200)
    ])

    assert_equal [ "daily_digest" ], result[:registered].map(&:registration_key)
    assert_equal 1, @project.monitors.where(registration_key: "daily_digest").count
    # The last occurrence wins — the value the row is left with either way.
    monitor = @project.monitors.find_by(registration_key: "daily_digest")
    assert_equal "Second", monitor.name
    assert_equal 7200, monitor.expected_interval_seconds
  end

  # The same collapse on the create path, and it must not burn two cap slots for
  # one monitor.
  test "a repeated NEW key consumes one cap slot and reports once" do
    # bob has 1 fixture monitor; cap 5 -> 4 slots for 3 distinct new keys.
    result = @project.sync_monitors(entries: [
      entry("a"), entry("b"), entry("a"), entry("c"), entry("b")
    ])

    assert_equal %w[a b c], result[:registered].map(&:registration_key)
    assert_empty result[:skipped]
    assert_equal 4, @user.reload.monitors.count
  end

  # A repeat must not double-report the shared-key collision either.
  test "a repeated key with a diverging app reports one conflict" do
    @project.sync_monitors(app: "billing-app", entries: [ entry("heartbeat") ])

    result = @project.sync_monitors(app: "worker-app", entries: [ entry("heartbeat"), entry("heartbeat") ])

    assert_equal [ "heartbeat" ], result[:conflicts]
  end

  test "a concurrent create of the same key (RecordNotUnique) is upserted, not raised" do
    # The race: a sibling boot process already inserted this key, but THIS run's
    # lookup ran before that insert landed, so it takes the create path and the
    # partial unique index raises RecordNotUnique. The operation must recover by
    # updating the now-existing row, never 500.
    #
    # Staged through the ONE thing the race breaks — the lookup missing a row that
    # is already committed. Everything else is real: the create path runs, the
    # partial unique index fires for real, and the rescue's re-find + update runs.
    # Blinding the lookup is what a stale read looks like from in here; a true
    # two-connection race can't be staged under transactional fixtures.
    @project.monitors.create!(
      registration_key: "racey", name: "Original", expected_interval_seconds: 3600,
      grace_period_seconds: 300, source: "gem", status: "pending",
      last_synced_name: "Original", last_synced_expected_interval_seconds: 3600,
      last_synced_grace_period_seconds: 300
    )

    # Only the racing key's FIRST lookup is blind. That's the shape of the race:
    # the sync's own lookup missed, and by the time the insert has conflicted the
    # row is plainly there for the rescue to re-find. Blinding every lookup would
    # stage a different bug — and pass while the recovery was broken.
    #
    # Staged on `where` because that is the lookup the operation makes: it
    # preloads the whole payload's rows in one query and re-finds only in the
    # rescue (which reaches the same seam, since find_by is where(...).take).
    # Keyed on the registration key rather than on call order, and backed by the
    # count assertion below, because a blind FIRST-CALL would be spent by any
    # other lookup the operation happens to make first — after which the sync's
    # own lookup finds the row, takes the update path, and every assertion here
    # still passes with the RecordNotUnique recovery deleted outright.
    lookup = @project.monitors.method(:where)
    racey_lookups = 0
    stale_read = lambda do |*args, **kwargs|
      conditions = kwargs.presence || args.first
      racing = conditions.is_a?(Hash) &&
        Array(conditions.symbolize_keys[:registration_key]).include?("racey")
      relation = lookup.call(*args, **kwargs)
      next relation unless racing

      (racey_lookups += 1) == 1 ? relation.where.not(registration_key: "racey") : relation
    end

    result = @project.monitors.stub(:where, stale_read) do
      @project.sync_monitors(entries: [ entry("racey", name: "Updated", interval: 7200) ])
    end

    assert_equal 2, racey_lookups,
      "the recovery never ran: the create path must miss, hit the unique index, then re-find the row"
    assert_empty result[:skipped]
    assert_equal [ "racey" ], result[:registered].map(&:registration_key)
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

  # M8 — the shape check reads the numbers through to_i, where nil and garbage both
  # become a valid grace of 0, so at the cap a malformed entry came back as
  # "limit_reached" — telling the operator to buy slots for an entry that would
  # never have registered.
  test "a malformed grace_period_seconds reports invalid, not limit_reached, at the cap" do
    @project.sync_monitors(entries: (1..4).map { |i| entry("k#{i}") })
    assert @user.reload.at_monitor_cap?

    result = @project.sync_monitors(entries: [
      { registration_key: "nil_grace", name: "N", expected_interval_seconds: 3600, grace_period_seconds: nil },
      { registration_key: "junk_grace", name: "J", expected_interval_seconds: 3600, grace_period_seconds: "soon" },
      { registration_key: "junk_interval", name: "I", expected_interval_seconds: "hourly", grace_period_seconds: 300 }
    ])

    assert_equal [ "invalid" ], result[:skipped].map { |s| s[:reason] }.uniq
    assert_equal %w[nil_grace junk_grace junk_interval], result[:skipped].map { |s| s[:registration_key] }
  end

  # Under the cap the model's own validations already refuse these, so the shape
  # check must agree with them: same classification, and no monitor created.
  test "a malformed entry is invalid under the cap too" do
    result = @project.sync_monitors(entries: [
      { registration_key: "nil_grace", name: "N", expected_interval_seconds: 3600, grace_period_seconds: nil }
    ])

    assert_equal [ { registration_key: "nil_grace", reason: "invalid" } ], result[:skipped]
    refute @project.monitors.exists?(registration_key: "nil_grace")
  end

  # A zero grace is legitimate ("ping exactly on time"), and must not be swept up
  # with the malformed ones.
  test "a zero grace_period_seconds is a valid shape" do
    result = @project.sync_monitors(entries: [ entry("prompt", grace: 0) ])

    assert_empty result[:skipped]
    assert_equal 0, @project.monitors.find_by(registration_key: "prompt").grace_period_seconds
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

  # --- F2: user overrides survive a re-sync ---------------------------------

  # The gem re-syncs on every production boot, and the update path used to
  # overwrite name/interval/grace unconditionally — so a user who tightened a
  # monitor in the UI (which locked decision #5 and docs/integrating.md
  # explicitly invite) had all three silently reverted at the next deploy.
  test "a re-sync preserves the settings the user changed in the UI" do
    @project.sync_monitors(entries: [ entry("digest", name: "digest", interval: 3600, grace: 300) ])
    monitor = @project.monitors.find_by(registration_key: "digest")
    monitor.update!(name: "Nightly digest", expected_interval_seconds: 900, grace_period_seconds: 60)

    # The next deploy: same recurring.yml, so the gem sends exactly what it sent
    # before. Nothing about the schedule has changed, so nothing may be reverted.
    result = @project.sync_monitors(entries: [ entry("digest", name: "digest", interval: 3600, grace: 300) ])

    assert_equal [ "digest" ], result[:registered].map(&:registration_key)
    monitor.reload
    assert_equal "Nightly digest", monitor.name
    assert_equal 900, monitor.expected_interval_seconds
    assert_equal 60, monitor.grace_period_seconds
  end

  # The payload arrives from JSON, where the numbers are strings. Comparing a
  # string against the stored integer would make every boot look like a schedule
  # change and hand the gem back its clobber.
  test "a re-sync sending its numbers as strings is not a schedule change" do
    @project.sync_monitors(entries: [ entry("digest", interval: 3600, grace: 300) ])
    @project.monitors.find_by(registration_key: "digest").update!(expected_interval_seconds: 900)

    @project.sync_monitors(entries: [
      { registration_key: "digest", name: "digest",
        expected_interval_seconds: "3600", grace_period_seconds: "300" }
    ])

    assert_equal 900, @project.monitors.find_by(registration_key: "digest").expected_interval_seconds
  end

  # PRECEDENCE (the deliberate call): when the user has overridden a value AND
  # recurring.yml genuinely changes it, the gem wins. The interval describes how
  # often the job actually runs; once that changes, an override derived from the
  # old schedule is stale and would false-alarm — the failure this product exists
  # to prevent. The user's override is only protected from being undone by a
  # re-sync that says nothing new. See #gem_may_write?.
  test "a genuine recurring.yml change overrides the user's own value" do
    @project.sync_monitors(entries: [ entry("digest", name: "digest", interval: 3600, grace: 300) ])
    monitor = @project.monitors.find_by(registration_key: "digest")
    monitor.update!(name: "Nightly digest", expected_interval_seconds: 900, grace_period_seconds: 60)

    # recurring.yml now says hourly -> every two hours (and renames the task).
    @project.sync_monitors(entries: [ entry("digest", name: "Two-hourly digest", interval: 7200, grace: 600) ])

    monitor.reload
    assert_equal "Two-hourly digest", monitor.name
    assert_equal 7200, monitor.expected_interval_seconds
    assert_equal 600, monitor.grace_period_seconds
  end

  # Each setting is judged on its own: a schedule change to the interval must not
  # drag a name the user rewrote along with it.
  test "an overridden setting survives a change to a different one" do
    @project.sync_monitors(entries: [ entry("digest", name: "digest", interval: 3600, grace: 300) ])
    monitor = @project.monitors.find_by(registration_key: "digest")
    monitor.update!(name: "Nightly digest")

    @project.sync_monitors(entries: [ entry("digest", name: "digest", interval: 7200, grace: 300) ])

    monitor.reload
    assert_equal "Nightly digest", monitor.name
    assert_equal 7200, monitor.expected_interval_seconds
  end

  # No override: the gem still owns the values, and a schedule change lands.
  test "an untouched monitor still tracks recurring.yml" do
    @project.sync_monitors(entries: [ entry("digest", name: "digest", interval: 3600, grace: 300) ])

    @project.sync_monitors(entries: [ entry("digest", name: "Digest", interval: 7200, grace: 600) ])

    monitor = @project.monitors.find_by(registration_key: "digest")
    assert_equal "Digest", monitor.name
    assert_equal 7200, monitor.expected_interval_seconds
    assert_equal 600, monitor.grace_period_seconds
  end

  # A monitor registered before this shipped remembers nothing, and "we don't
  # know what the gem last sent" must mean "leave the user's values alone" — the
  # first sync after the deploy is exactly when the clobber used to happen. It
  # starts remembering, so genuine schedule changes propagate from then on.
  test "a monitor with nothing remembered is not reverted on the first re-sync" do
    monitor = @project.monitors.create!(
      registration_key: "legacy", name: "Renamed by hand", expected_interval_seconds: 900,
      grace_period_seconds: 60, source: "gem", status: "pending"
    )
    assert_nil monitor.last_synced_expected_interval_seconds

    @project.sync_monitors(entries: [ entry("legacy", name: "legacy", interval: 3600, grace: 300) ])

    monitor.reload
    assert_equal "Renamed by hand", monitor.name
    assert_equal 900, monitor.expected_interval_seconds
    assert_equal 60, monitor.grace_period_seconds
    assert_equal 3600, monitor.last_synced_expected_interval_seconds

    # ...and from here on a real schedule change is applied as normal.
    @project.sync_monitors(entries: [ entry("legacy", name: "legacy", interval: 10_800, grace: 300) ])
    assert_equal 10_800, monitor.reload.expected_interval_seconds
  end

  # The known limit of that rule, pinned so it can't drift unnoticed: a schedule
  # change already IN FLIGHT when we started remembering is refused for as long as
  # the payload keeps repeating it. On the first sync a divergence is equally
  # consistent with "the user tightened this" and "the schedule changed", and we
  # resolve it toward never overwriting a setting the user may have chosen — so
  # this monitor keeps its old cadence until the schedule changes again.
  test "a schedule change in flight when we start remembering waits for the next change" do
    monitor = @project.monitors.create!(
      registration_key: "legacy", name: "legacy", expected_interval_seconds: 3600,
      grace_period_seconds: 300, source: "gem", status: "pending"
    )
    assert_nil monitor.last_synced_expected_interval_seconds

    # The same, unchanged payload arriving repeatedly never lands.
    3.times do
      @project.sync_monitors(entries: [ entry("legacy", name: "legacy", interval: 7200, grace: 300) ])
    end
    assert_equal 3600, monitor.reload.expected_interval_seconds,
      "an in-flight change is refused while the payload keeps repeating it"
    assert_equal 7200, monitor.last_synced_expected_interval_seconds

    # A genuinely NEW schedule change does land, which is how it recovers.
    @project.sync_monitors(entries: [ entry("legacy", name: "legacy", interval: 1800, grace: 300) ])
    assert_equal 1800, monitor.reload.expected_interval_seconds
  end

  test "a newly created monitor remembers what the gem sent" do
    result = @project.sync_monitors(entries: [ entry("fresh", name: "Fresh", interval: 3600, grace: 300) ])
    monitor = result[:registered].first

    assert_equal "Fresh", monitor.last_synced_name
    assert_equal 3600, monitor.last_synced_expected_interval_seconds
    assert_equal 300, monitor.last_synced_grace_period_seconds
  end

  # A gem that sends no name at all leaves the monitor named after its key; the
  # remembered name has to be that same defaulted value, or the next sync would
  # read the default as a user rename.
  test "a monitor named after its key is not mistaken for a rename" do
    @project.sync_monitors(entries: [
      { registration_key: "cleanup", expected_interval_seconds: 3600, grace_period_seconds: 300 }
    ])

    monitor = @project.monitors.find_by(registration_key: "cleanup")
    assert_equal "cleanup", monitor.last_synced_name
  end

  # F2 x F7: next_due_at is re-derived whenever the interval changes, so a sync
  # that leaves the user's interval alone must leave the due time alone too —
  # otherwise the revert would come back through the back door as a detection
  # window the user never asked for.
  test "a preserved interval leaves next_due_at on the user's cadence" do
    @project.sync_monitors(entries: [ entry("digest", interval: 3600, grace: 300) ])
    monitor = @project.monitors.find_by(registration_key: "digest")
    monitor.register_contact(Time.current)
    monitor.save!
    monitor.update!(expected_interval_seconds: 900)
    user_due_at = monitor.reload.next_due_at

    @project.sync_monitors(entries: [ entry("digest", interval: 3600, grace: 300) ])

    assert_equal user_due_at, monitor.reload.next_due_at
    assert_equal monitor.last_ping_at + 900.seconds, monitor.next_due_at
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
  # user row for the slot accounting to be atomic.
  #
  # Read off the SELECT … FOR UPDATE the database actually receives, rather than by
  # patching #with_lock onto the two records and watching which one is called:
  # locking is what the statement does, and any other route to it — a bare
  # `lock!`, a `where(...).lock` — counts just the same.
  test "sync holds the row lock on the user, not the project" do
    locks = sql_executed_during { @project.sync_monitors(entries: [ entry("x") ]) }
      .grep(/FOR UPDATE/)

    assert locks.any? { |sql| sql.match?(/FROM "users"/) },
      "the slot accounting must serialise on the shared user row: #{locks.inspect}"
    assert_empty locks.grep(/FROM "projects"/),
      "locking the project leaves a user's other projects free to race for the same slots"
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
