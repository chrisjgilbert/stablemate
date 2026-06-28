# Recurring detection sweep (every DETECTION_INTERVAL, see config/recurring.yml).
# Orchestration only: it iterates the overdue scope and delegates the actual
# transition/incident/alert work to the record (Monitoring::Monitor::MissedPing).
# No domain logic, no outbound HTTP here.
class DetectMissedPingsJob < ApplicationJob
  queue_as :default

  def perform
    Monitoring::Monitor.overdue.find_each(&:flag_missed!)
  end
end
