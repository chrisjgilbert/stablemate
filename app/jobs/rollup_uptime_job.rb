# Recurring daily rollup (see config/recurring.yml). Orchestration only: it
# iterates monitors and delegates each day's aggregation to the record
# (monitor.roll_up_uptime). No domain logic here.
#
# For each monitor it rolls up every complete day not yet rolled, up to and
# including yesterday — so a missed run is backfilled on the next run. The
# day-range rule (backfill window, retention/creation clamps) lives on the record
# (monitor.uptime_days_to_roll); the job only iterates and delegates.
class RollupUptimeJob < ApplicationJob
  queue_as :default

  def perform
    Monitoring::Monitor.find_each do |monitor|
      monitor.uptime_days_to_roll.each { |day| monitor.roll_up_uptime(day) }
    end
  end
end
