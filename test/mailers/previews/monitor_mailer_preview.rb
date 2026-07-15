# Preview all emails at http://localhost:3000/rails/mailers/monitor_mailer
class MonitorMailerPreview < ActionMailer::Preview
  def down
    MonitorMailer.down(Monitoring::Monitor.first)
  end

  def down_reported_error
    monitor = Monitoring::Monitor.first
    incident = Incident.new(
      monitor:, started_at: Time.current, cause: "reported_error",
      error: "ActiveRecord::Deadlocked: deadlock detected (PG::TRDeadlockDetected)"
    )
    MonitorMailer.down(monitor, incident:)
  end

  def recovered
    MonitorMailer.recovered(Monitoring::Monitor.first)
  end
end
