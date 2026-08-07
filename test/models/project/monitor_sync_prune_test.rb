require "test_helper"

# The server half of prune (v1-scope §6.1). The sync computes the orphan set
# itself — it is the only party that sees both sides — reports it by default,
# retires it only on a PRUNE run, and destroys nothing ever.
#
# All of it is inert until a 0.2.0 gem sends the new fields: a pre-0.2.0 gem
# sends neither `prune` nor `declared_keys`, and prune without declared_keys
# retires nothing.
class Project::MonitorSyncPruneTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  # carol owns no monitors, so this file's counts are only what it creates.
  setup do
    @user = users(:carol)
    @project = @user.projects.sole
  end

  def entry(key, name: nil, interval: 3600, grace: 300, schedule: nil)
    { registration_key: key, name: name || key, schedule:,
      expected_interval_seconds: interval, grace_period_seconds: grace }
  end

  def sync(keys, app: "my-app", prune: false, declared_keys: :same_as_payload)
    declared_keys = keys if declared_keys == :same_as_payload
    @project.sync_monitors(app:, entries: keys.map { |k| entry(k) },
                           prune:, declared_keys:)
  end

  def monitor(key) = @project.monitors.find_by!(registration_key: key)

  # --- Reporting orphans (default) -------------------------------------------

  test "a task that left the config is reported and left completely alone" do
    sync(%w[daily_digest nightly_backup])
    monitor("nightly_backup").check_in!

    result = sync(%w[daily_digest])

    assert_equal [ "nightly_backup" ], result[:orphaned]
    assert_empty result[:retired]
    assert_equal "up", monitor("nightly_backup").status
  end

  # Two apps syncing distinct task sets into one project must not orphan each
  # other's monitors on every run.
  test "another app's monitors are never this run's orphans" do
    sync(%w[web_task], app: "web")
    sync(%w[worker_task], app: "worker")

    assert_empty sync(%w[web_task], app: "web")[:orphaned]
    assert_empty sync(%w[worker_task], app: "worker")[:orphaned]
  end

  # A row with NULL last_synced_app cannot be attributed to any app, so no run may
  # claim it — nil-matches-nil would hand every unattributed row to whichever app
  # syncs first.
  test "a monitor with no recorded app is never a candidate" do
    @project.sync_monitors(entries: [ entry("unattributed") ]) # no app
    assert_nil monitor("unattributed").last_synced_app

    assert_empty sync(%w[daily_digest], app: "my-app")[:orphaned]
  end

  test "a payload that names no app reports no orphans at all" do
    sync(%w[daily_digest], app: "my-app")

    result = @project.sync_monitors(entries: [ entry("other") ])
    assert_empty result[:orphaned]
  end

  # The §8 backfill leaves a permanent `manual-<id>` population that is not
  # declared in any repo. The source check is what keeps it out of orphan reports
  # forever — and is why the `source` column survives V1.
  test "a backfilled manual monitor never appears as an orphan" do
    @project.monitors.create!(name: "Hand made", registration_key: "manual-7", source: "manual",
                              expected_interval_seconds: 3600, grace_period_seconds: 300,
                              last_synced_app: "my-app")

    assert_empty sync(%w[daily_digest])[:orphaned]
  end

  test "an entry the server refused is still a task this run sent, not an orphan" do
    sync(%w[daily_digest])

    result = @project.sync_monitors(app: "my-app", declared_keys: %w[daily_digest broken],
                                    entries: [ entry("daily_digest"), entry("broken", interval: 0) ])

    assert_equal "invalid", result[:skipped].sole[:reason]
    assert_empty result[:orphaned]
  end

  test "an already-retired monitor is not re-reported on every run" do
    sync(%w[daily_digest nightly_backup])
    sync(%w[daily_digest], prune: true)

    result = sync(%w[daily_digest])
    assert_empty result[:orphaned]
    assert_empty result[:retired]
  end

  # --- Retiring, on PRUNE only -----------------------------------------------

  test "prune retires a truly-absent task's monitor and keeps its history" do
    sync(%w[daily_digest nightly_backup])
    monitor("nightly_backup").check_in!

    result = sync(%w[daily_digest], prune: true)

    assert_equal [ "nightly_backup" ], result[:retired]
    assert_empty result[:orphaned]
    assert_equal "retired", monitor("nightly_backup").status
    assert_equal 1, monitor("nightly_backup").ping_events.count
  end

  # A task still IN recurring.yml whose class: line was deleted, or whose schedule
  # no longer parses, is skipped by the registrar and stops matching its monitor —
  # so it reads exactly like an orphan. Auto-retiring it would turn a YAML typo
  # into monitoring-off for a live job. Only the CLI can tell the two apart, which
  # is what declared_keys is for.
  test "a task that is present but not registerable is reported, never retired" do
    sync(%w[daily_digest nightly_backup])

    result = @project.sync_monitors(app: "my-app", prune: true,
                                    declared_keys: %w[daily_digest nightly_backup],
                                    entries: [ entry("daily_digest") ])

    assert_equal [ "nightly_backup" ], result[:orphaned]
    assert_empty result[:retired]
    assert_equal "pending", monitor("nightly_backup").status
  end

  # Every pre-0.2.0 gem sends the flag never, and a forged one can send it without
  # a key list — either way there is nothing to bound the retire set, so nothing
  # is retired.
  test "prune with no declared_keys retires nothing at all" do
    sync(%w[daily_digest nightly_backup])

    [ nil, [] ].each do |declared|
      result = sync(%w[daily_digest], prune: true, declared_keys: declared)
      assert_empty result[:retired]
      assert_equal "pending", monitor("nightly_backup").status
    end
  end

  # There is no client-supplied list of keys to retire: the server computes the
  # set and re-applies its own orphan rule to every retirement, so a minimal
  # payload with the flag set cannot reach a backfilled row or another app's
  # monitors.
  test "a minimal prune payload cannot reach a backfill or another app's monitors" do
    backfilled = @project.monitors.create!(name: "Hand made", registration_key: "manual-7",
                                           source: "manual", last_synced_app: "my-app",
                                           expected_interval_seconds: 3600, grace_period_seconds: 300)
    sync(%w[worker_task], app: "worker")

    result = @project.sync_monitors(app: "my-app", prune: true, declared_keys: %w[anything],
                                    entries: [ entry("anything") ])

    assert_empty result[:retired]
    assert_equal "manual", backfilled.reload.source
    assert_not_equal "retired", backfilled.status
    assert_not_equal "retired", monitor("worker_task").status
  end

  test "retiring a monitor mid-outage resolves its incident without an alert" do
    sync(%w[daily_digest nightly_backup])
    down = monitor("nightly_backup")
    down.check_in!(kind: "failure", error: "boom")
    assert_equal "down", down.reload.status

    assert_no_emails do
      perform_enqueued_jobs { sync(%w[daily_digest], prune: true) }
    end

    assert_not_nil down.incidents.sole.resolved_at
  end

  # --- Reviving ---------------------------------------------------------------

  test "a returning task revives its monitor with no alert and a fresh window" do
    sync(%w[daily_digest nightly_backup])
    monitor("nightly_backup").check_in!
    sync(%w[daily_digest], prune: true)

    revived_at = 3.days.from_now
    travel_to(revived_at) do
      assert_no_difference -> { Incident.count } do
        assert_no_emails { perform_enqueued_jobs { sync(%w[daily_digest nightly_backup]) } }
      end

      revived = monitor("nightly_backup")
      assert_equal "up", revived.status
      assert_in_delta revived_at + 1.hour, revived.next_due_at, 1.second
      assert_includes @project.monitors.where(id: revived.id), revived
    end
  end

  test "a revive lands in the run's registered set and takes the new settings" do
    sync(%w[nightly_backup])
    sync([], prune: true, declared_keys: %w[other])

    result = @project.sync_monitors(app: "my-app", declared_keys: %w[nightly_backup],
                                    entries: [ entry("nightly_backup", interval: 7200) ])

    assert_equal [ "nightly_backup" ], result[:registered].map(&:registration_key)
    revived = monitor("nightly_backup")
    assert_equal "up", revived.status
    assert_equal 7200, revived.expected_interval_seconds
    # The re-armed window is measured against the interval this run registered,
    # not the one the monitor retired with, and never from the pre-retirement ping.
    assert_in_delta 2.hours.from_now, revived.next_due_at, 5.seconds
  end

  # within_monitor_cap validates on: :create only, and the find-then-update path is
  # deliberately "always allowed at the cap" — so without an explicit branch you
  # could retire one, fill the freed slot, and restore the first: silently over cap.
  test "a revive at the cap is refused as limit_reached and stays retired" do
    limit = Stablemate::FREE_PLAN_MONITOR_LIMIT
    sync((1..limit).map { |i| "task_#{i}" })
    sync((2..limit).map { |i| "task_#{i}" }, prune: true)
    assert_equal "retired", monitor("task_1").status

    sync((2..limit).map { |i| "task_#{i}" } + %w[filler])
    assert_equal limit, @user.reload.monitors.counting_toward_cap.count

    result = sync((1..limit).map { |i| "task_#{i}" } + %w[filler])

    assert_includes result[:skipped], { registration_key: "task_1", reason: "limit_reached" }
    assert_equal "retired", monitor("task_1").status
    assert_not_includes result[:registered].map(&:registration_key), "task_1"
  end

  # The key is the identity, so a rename is an add plus an orphan. History does
  # not follow it — that is the one honest limit of convergence.
  test "a rename plus prune retires the old monitor and starts the new key fresh" do
    sync(%w[old_report])
    monitor("old_report").check_in!

    result = sync(%w[new_report], prune: true)

    assert_equal [ "old_report" ], result[:retired]
    assert_equal "retired", monitor("old_report").status
    assert_equal 1, monitor("old_report").ping_events.count
    assert_equal "pending", monitor("new_report").status
    assert_equal 0, monitor("new_report").ping_events.count
  end

  # --- The schedule string rides along and does nothing (§6.3) ---------------

  test "a cron task stores its schedule string and an interval declaration stores NULL" do
    @project.sync_monitors(app: "my-app", entries: [
      entry("reports.daily", schedule: "0 9 * * *"),
      entry("pg_backup", interval: 86_400)
    ])

    assert_equal "0 9 * * *", monitor("reports.daily").schedule
    assert_nil monitor("pg_backup").schedule
  end

  test "the stored schedule changes nothing about detection timing" do
    @project.sync_monitors(app: "my-app", entries: [
      entry("with_schedule", schedule: "0 * * * *"), entry("without_schedule")
    ])
    @project.monitors.find_each { |m| m.check_in!(received_at: Time.current) }

    travel_to(1.hour.from_now + 6.minutes) do
      overdue = Monitoring::Monitor.overdue.where(project: @project).pluck(:registration_key)
      assert_equal %w[with_schedule without_schedule], overdue.sort
    end
  end

  test "an absent schedule leaves a stored one alone, as every other setting does" do
    @project.sync_monitors(app: "my-app", entries: [ entry("reports.daily", schedule: "0 9 * * *") ])
    @project.sync_monitors(app: "my-app", entries: [ entry("reports.daily") ])

    assert_equal "0 9 * * *", monitor("reports.daily").schedule
  end
end
