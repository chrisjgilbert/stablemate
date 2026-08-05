require "test_helper"

# [job] PrunePingEventsJob deletes raw PingEvents older than PING_RETENTION, in
# batches, and never prunes a day that hasn't been rolled up yet (safety check).
# Assertions are relative to the PING_RETENTION constant, never hard-coded days.
class PrunePingEventsJobTest < ActiveJob::TestCase
  RAILS_IN_BATCHES_DEFAULT = 1000

  setup do
    Monitoring::Monitor.delete_all
    @project = users(:alice).projects.sole
    @monitor = @project.monitors.create!(
      name: "Prune target",
      expected_interval_seconds: 3600,
      grace_period_seconds: 300,
      status: "up"
    )
    @monitor.update_column(:created_at, (Stablemate::PING_RETENTION.ago - 30.days))
  end

  # Scenario 11 — old pings are deleted, recent ones retained. Old days are rolled
  # up first so the safety check passes.
  test "deletes pings older than the retention window and keeps newer ones" do
    old_time   = Stablemate::PING_RETENTION.ago - 2.days
    fresh_time = 1.day.ago

    old   = @monitor.ping_events.create!(received_at: old_time, kind: "success")
    fresh = @monitor.ping_events.create!(received_at: fresh_time, kind: "success")
    # Safety check requires the old ping's day to be rolled up.
    @monitor.uptime_day_stats.create!(day: old_time.to_date, up_seconds: 86_400, down_seconds: 0, ping_count: 1)

    PrunePingEventsJob.perform_now

    assert_not PingEvent.exists?(old.id)
    assert PingEvent.exists?(fresh.id)
  end

  # Scenario 12 — an old ping whose day has NO UptimeDayStat is skipped + logged,
  # never deleted blind. The day has to be one the rollup can still reach (the
  # horizon day: prunable, because the retention cutoff falls at midday, but
  # still inside the backfill window) — see the M11 case below for the days it
  # can't.
  test "skips and logs pruning for a rollable day that has not been rolled up" do
    travel_to Date.current.to_time(:utc) + 12.hours do
      old_time = Monitoring::Monitor.uptime_backfill_horizon.to_time(:utc) + 3.hours
      old = @monitor.ping_events.create!(received_at: old_time, kind: "success")
      # Deliberately no UptimeDayStat for old_time.to_date.

      logs = capturing_logs { PrunePingEventsJob.perform_now }

      assert PingEvent.exists?(old.id), "un-rolled day's pings must not be deleted"
      assert_match(/skipping un-rolled day/, logs)
    end
  end

  # M11 — the prune/rollup deadlock: uptime_days_to_roll clamps a never-rolled
  # monitor's backfill at the retention horizon, so a day older than that can
  # never gain an UptimeDayStat. Demanding one there protected nothing and
  # stranded those raw pings for ever (skipped + warn-logged on every run).
  test "prunes a pre-horizon day the rollup can never reach" do
    travel_to Date.current.to_time(:utc) + 12.hours do
      horizon = Monitoring::Monitor.uptime_backfill_horizon
      @monitor.update_column(:created_at, (horizon - 10.days).to_time(:utc))

      stranded = @monitor.ping_events.create!(received_at: (horizon - 1.day).to_time(:utc) + 3.hours, kind: "success")
      rollable = @monitor.ping_events.create!(received_at: horizon.to_time(:utc) + 3.hours, kind: "success")

      # The premise: the backfill starts at the horizon, so the older day is
      # unreachable no matter how many times the rollup job runs.
      assert_not_includes @monitor.uptime_days_to_roll, horizon - 1.day

      PrunePingEventsJob.perform_now

      assert_not PingEvent.exists?(stranded.id), "an unreachable day's pings must not be stranded for ever"
      assert PingEvent.exists?(rollable.id), "the horizon day is still rollable — keep the safety check"
    end
  end

  # Scenario 13 — read through the SQL, not by patching ActiveRecord::Relation to
  # catch a call to #in_batches: batching is observable (past the batch size it
  # issues more than one delete, each bounded by an id set), and the patch was one
  # skipped `ensure` away from breaking every later test in the worker.
  test "deletes in batches rather than in one statement over the whole backlog" do
    old_time = Stablemate::PING_RETENTION.ago - 2.days
    # One more than Rails' in_batches default, so the delete cannot fit in a
    # single batch. If that default grows this fails visibly, with one statement.
    rows = (RAILS_IN_BATCHES_DEFAULT + 1).times.map do
      { monitor_id: @monitor.id, received_at: old_time, kind: "success",
        created_at: Time.current }
    end
    PingEvent.insert_all!(rows)
    @monitor.uptime_day_stats.create!(day: old_time.to_date, up_seconds: 86_400, down_seconds: 0, ping_count: 1)

    deletes = sql_executed_during { PrunePingEventsJob.perform_now }
      .grep(/\ADELETE FROM "ping_events"/)

    assert_operator deletes.size, :>=, 2,
      "#{rows.size} doomed rows must be deleted across several statements, not one"
    # Each batch names the ids it is deleting — `IN (…)` for a full batch, `= $n`
    # for a final batch of one. Either way the statement is bounded by the batch,
    # which is the property that keeps a huge backlog off the heap.
    assert deletes.all? { |sql| sql.match?(/"id" (IN|=)/) },
      "each batch must delete a bounded, explicit id set: #{deletes.map { |s| s[/"id".{0,8}/] }.inspect}"
    assert_equal 0, @monitor.ping_events.where("received_at::date = ?", old_time.to_date).count,
      "and the backlog must actually be gone afterwards"
  end

  # The prunable scope rule lives on the record (received_at < PING_RETENTION.ago).
  test "the prunable scope selects only events older than the retention window" do
    freeze_time do
      old   = @monitor.ping_events.create!(received_at: Stablemate::PING_RETENTION.ago - 1.second, kind: "success")
      fresh = @monitor.ping_events.create!(received_at: Stablemate::PING_RETENTION.ago + 1.hour, kind: "success")

      ids = PingEvent.prunable.pluck(:id)
      assert_includes ids, old.id
      assert_not_includes ids, fresh.id
    end
  end
end
