require "test_helper"
require Rails.root.join("db/migrate/20260807112619_backfill_monitor_registration_keys")

# registration_key becomes the monitor's public address (v1-scope §5.1), so every
# pre-existing monitor needs one. The migration is exercised directly rather than
# through db:migrate: the test schema is loaded from schema.rb, so this is the
# only way the shipped backfill code is ever run by the suite.
class BackfillMonitorRegistrationKeysTest < ActiveSupport::TestCase
  # Carol starts with no monitors, so this file controls its own monitor set and
  # never brushes the plan cap while building collision scenarios.
  setup do
    @carol = users(:carol)
    @project = @carol.projects.sole
  end

  def backfill
    ActiveRecord::Migration.suppress_messages do
      BackfillMonitorRegistrationKeys.new.up
    end
  end

  def keyless_monitor(name:)
    @project.monitors.create!(name:, expected_interval_seconds: 3600,
                              grace_period_seconds: 300, source: "manual")
  end

  # §12: every monitor without a task name gets a distinct, usable, slash-free one.
  test "every keyless monitor gets a distinct, slash-free key" do
    backfill

    keys = Monitoring::Monitor.pluck(:registration_key)
    assert_empty keys.select(&:nil?), "every monitor should be addressable after the backfill"
    assert_equal keys.size, keys.uniq.size, "keys must be distinct"

    backfilled = keys.grep(/\Amanual-/)
    assert_predicate backfilled, :any?
    backfilled.each { |key| refute_includes key, "/", "a key with a slash is not addressable" }
  end

  test "the backfill leaves keys the sync already assigned alone" do
    synced = monitors(:gem_synced)
    backfill
    assert_equal "daily_digest", synced.reload.registration_key
  end

  # §8.1: the namespace is the point. A name-derived key would let the next
  # stablemate:sync ADOPT a hand-created monitor that happens to share a job's
  # name — two monitors silently becoming one.
  test "a backfilled key is never derived from the monitor's name" do
    hand_made = keyless_monitor(name: "daily_digest")
    backfill

    assert_equal "manual-#{hand_made.id}", hand_made.reload.registration_key
  end

  # §12 / §8: `manual-7` is a string a human can type into recurring.yml, and the
  # partial unique index would otherwise raise RecordNotUnique, roll back the
  # wrapping transaction and fail the deploy.
  test "a task key that collides with a generated one does not raise" do
    keyless = keyless_monitor(name: "Hand made")
    @project.monitors.create!(name: "Declared in recurring.yml", source: "gem",
                              registration_key: "manual-#{keyless.id}",
                              expected_interval_seconds: 3600, grace_period_seconds: 300)

    assert_nothing_raised { backfill }

    assert_equal "manual-#{keyless.id}-2", keyless.reload.registration_key
  end

  test "consecutive collisions keep suffixing until a key is free" do
    keyless = keyless_monitor(name: "Hand made")
    [ "manual-#{keyless.id}", "manual-#{keyless.id}-2" ].each_with_index do |key, i|
      @project.monitors.create!(name: "Declared #{i}", source: "gem", registration_key: key,
                                expected_interval_seconds: 3600, grace_period_seconds: 300)
    end

    backfill

    assert_equal "manual-#{keyless.id}-3", keyless.reload.registration_key
  end

  # Uniqueness is scoped to the project, so the same key in another project is not
  # a collision and must not push the backfill onto a suffix.
  test "the same key in another project is not a collision" do
    keyless = keyless_monitor(name: "Hand made")
    other = @carol.projects.create!(name: "Other app")
    other.monitors.create!(name: "Elsewhere", source: "gem",
                           registration_key: "manual-#{keyless.id}",
                           expected_interval_seconds: 3600, grace_period_seconds: 300)

    backfill

    assert_equal "manual-#{keyless.id}", keyless.reload.registration_key
  end

  # §12 / §8.1, stated from the gem's side: after the backfill, a sync registering
  # a task named after a hand-created monitor creates a SECOND monitor rather than
  # adopting the first.
  test "a sync cannot adopt a backfilled monitor that shares a job's name" do
    hand_made = keyless_monitor(name: "daily_digest")
    backfill

    assert_difference -> { @project.monitors.count }, 1 do
      @project.sync_monitors(app: "my-app", entries: [
        { registration_key: "daily_digest", name: "daily_digest",
          expected_interval_seconds: 86_400, grace_period_seconds: 3600 }
      ])
    end

    assert_equal "manual-#{hand_made.id}", hand_made.reload.registration_key
    assert_equal "manual", hand_made.source
    assert_equal 3600, hand_made.expected_interval_seconds
  end
end
