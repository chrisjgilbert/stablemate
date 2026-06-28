require "test_helper"

# [job] RollupUptimeJob orchestrates only: it iterates monitors and delegates to
# monitor.roll_up_uptime(day), backfilling any un-rolled days up to yesterday.
class RollupUptimeJobTest < ActiveJob::TestCase
  setup do
    Monitoring::Monitor.delete_all
    @monitor = users(:alice).monitors.create!(
      name: "Job target",
      expected_interval_seconds: 3600,
      grace_period_seconds: 300,
      status: "up"
    )
    @monitor.update_column(:created_at, 5.days.ago)
  end

  # The job rolls up the previous complete day for every monitor.
  test "rolls up yesterday for each monitor" do
    freeze_time do
      assert_difference -> { @monitor.uptime_day_stats.where(day: Date.current - 1).count }, 1 do
        RollupUptimeJob.perform_now
      end
    end
  end

  # Scenario 5 — a missed run day is backfilled on the next run (a range, not just
  # yesterday). Here no prior stats exist, so the job fills the backfill window.
  test "backfills multiple un-rolled days in one run" do
    freeze_time do
      RollupUptimeJob.perform_now
      # At minimum yesterday and the day before are rolled (monitor is 5 days old).
      assert @monitor.uptime_day_stats.exists?(day: Date.current - 1)
      assert @monitor.uptime_day_stats.exists?(day: Date.current - 2)
    end
  end

  # Scenario 4 (via the job) — re-running is idempotent: no duplicate rows.
  test "re-running the job does not duplicate rolled days" do
    freeze_time do
      RollupUptimeJob.perform_now
      assert_no_difference -> { UptimeDayStat.count } do
        RollupUptimeJob.perform_now
      end
    end
  end

  # Orchestration only — it must not roll up today (the live, incomplete day).
  test "does not roll up the current incomplete day" do
    freeze_time do
      RollupUptimeJob.perform_now
      assert_not @monitor.uptime_day_stats.exists?(day: Date.current)
    end
  end
end
