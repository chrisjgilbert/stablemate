# Preview all emails at http://localhost:3000/rails/mailers/monitor_mailer
class MonitorMailerPreview < ActionMailer::Preview
  def down
    MonitorMailer.down(Monitoring::Monitor.first)
  end

  def recovered
    MonitorMailer.recovered(Monitoring::Monitor.first)
  end
end
