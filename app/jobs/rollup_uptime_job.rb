# Recurring daily rollup (see config/recurring.yml). Rolls up every complete day
# not yet rolled, so a missed run is backfilled on the next run.
class RollupUptimeJob < ApplicationJob
  queue_as :default

  def perform
    each_record(Monitoring::Monitor.all) do |monitor|
      monitor.uptime_days_to_roll.each { |day| monitor.roll_up_uptime(day) }
    end
  end
end
