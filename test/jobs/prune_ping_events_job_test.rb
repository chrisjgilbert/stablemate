require "test_helper"

# [job] PrunePingEventsJob deletes raw PingEvents older than PING_RETENTION, in
# batches, and never prunes a day that hasn't been rolled up yet (safety check).
# Assertions are relative to the PING_RETENTION constant, never hard-coded days.
class PrunePingEventsJobTest < ActiveJob::TestCase
  setup do
    Monitoring::Monitor.delete_all
    @monitor = users(:alice).monitors.create!(
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
  # never deleted blind.
  test "skips and logs pruning for a day that has not been rolled up" do
    old_time = Stablemate::PING_RETENTION.ago - 3.days
    old = @monitor.ping_events.create!(received_at: old_time, kind: "success")
    # Deliberately no UptimeDayStat for old_time.to_date.

    out = StringIO.new
    old_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(out)
    begin
      PrunePingEventsJob.perform_now
    ensure
      Rails.logger = old_logger
    end

    assert PingEvent.exists?(old.id), "un-rolled day's pings must not be deleted"
    assert_match(/skipping un-rolled day/, out.string)
  end

  # Scenario 13 — pruning deletes in batches (does not load all rows at once).
  # We assert the delete path goes through in_batches rather than a bare
  # delete_all over the whole relation.
  test "deletes in batches rather than loading every row at once" do
    old_time = Stablemate::PING_RETENTION.ago - 2.days
    3.times { @monitor.ping_events.create!(received_at: old_time, kind: "success") }
    @monitor.uptime_day_stats.create!(day: old_time.to_date, up_seconds: 86_400, down_seconds: 0, ping_count: 1)

    batched = false
    ActiveRecord::Relation.class_eval do
      alias_method :__orig_in_batches, :in_batches
    end
    ActiveRecord::Relation.define_method(:in_batches) do |*args, **kwargs, &blk|
      batched = true if model == PingEvent
      __orig_in_batches(*args, **kwargs, &blk)
    end

    begin
      PrunePingEventsJob.perform_now
    ensure
      ActiveRecord::Relation.class_eval do
        alias_method :in_batches, :__orig_in_batches
        remove_method :__orig_in_batches
      end
    end

    assert batched, "pruning must delete PingEvents via in_batches"
    assert_equal 0, @monitor.ping_events.where("received_at::date = ?", old_time.to_date).count
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
