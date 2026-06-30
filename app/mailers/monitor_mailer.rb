class MonitorMailer < ApplicationMailer
  # Alert: a monitor's ping is overdue and it's now considered down. Plain,
  # scannable email — name, what happened, expected-by time, link to detail.
  def down(monitor)
    @monitor = monitor
    @expected_by = monitor.due_with_grace_at

    mail to: monitor.user.email_address,
         subject: "#{monitor.name} missed its check-in"
  end

  # Alert: a previously-down monitor pinged again and has recovered.
  def recovered(monitor)
    @monitor = monitor

    mail to: monitor.user.email_address,
         subject: "#{monitor.name} is back up"
  end
end
