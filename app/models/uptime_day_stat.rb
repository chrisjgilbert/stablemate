class UptimeDayStat < ApplicationRecord
  belongs_to :monitor, class_name: "Monitoring::Monitor", inverse_of: :uptime_day_stats

  # Paused/pending windows are no-data and excluded from both columns, so a day
  # with no measurable seconds is no-data.
  def measured_seconds
    up_seconds + down_seconds
  end

  def status
    return :no_data if measured_seconds.zero?
    return :down if up_seconds.zero?
    return :up if down_seconds.zero?

    :partial
  end
end
