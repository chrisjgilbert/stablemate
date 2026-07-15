module Notifications
  # Command: deliver a Notification by email, wrapping MonitorMailer. The mailer
  # is the only email-specific code; this command picks the right action for the
  # event and marks the Notification delivered.
  class EmailChannel < Channel
    def deliver
      # The incident rides along so the mailer renders deterministically under
      # deliver_later (reading monitor.open_incident at render time would race a
      # fast recovery) and can branch its `down` copy on the incident's cause.
      MonitorMailer.send(@notification.event, @notification.monitor,
                         incident: @notification.incident).deliver_later
      # delivered_at marks "handed to the mail queue" (the alert was dispatched),
      # not "the SMTP server accepted it" — deliver_later enqueues a Solid Queue
      # job that does the actual send with its own retries. That's the right
      # granularity for the transition-only audit log in V1.
      @notification.update!(delivered_at: Time.current)
    end
  end
end
