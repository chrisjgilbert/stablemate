class UptimeDayStat < ApplicationRecord
  belongs_to :monitor, class_name: "Monitoring::Monitor", inverse_of: :uptime_day_stats

  # Seconds with measurable status: paused/pending windows are no-data and
  # excluded from both columns, so a day with no measurable seconds is no-data.
  def measured_seconds
    up_seconds + down_seconds
  end

  # Per-day status for the UptimeBar: down if the whole measured day was down,
  # partial if it saw any downtime, up if clean, no-data if nothing was measured.
  def status
    return :no_data if measured_seconds.zero?
    return :down if up_seconds.zero?
    return :up if down_seconds.zero?

    :partial
  end
end
