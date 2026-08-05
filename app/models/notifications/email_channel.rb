module Notifications
  class EmailChannel < Channel
    def deliver
      # The incident rides along so the mailer renders deterministically under
      # deliver_later — reading monitor.open_incident at render time would race a
      # fast recovery.
      MonitorMailer.send(@notification.event, @notification.monitor,
                         incident: @notification.incident).deliver_later
      # delivered_at marks "handed to the mail queue", not "the SMTP server
      # accepted it". Dispatch defers this whole method until the caller's
      # transaction commits, so the enqueue and the stamp stand or fall together.
      @notification.update!(delivered_at: Time.current)
    end
  end
end
