# Recurring detection sweep (every DETECTION_INTERVAL, see config/recurring.yml).
class DetectMissedPingsJob < ApplicationJob
  queue_as :default

  def perform
    each_record(Monitoring::Monitor.overdue, &:flag_missed!)
  end
end
