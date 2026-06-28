module Notifications
  # Command: deliver a Notification by email, wrapping MonitorMailer. The mailer
  # is the only email-specific code; this command picks the right action for the
  # event and marks the Notification delivered.
  class EmailChannel < Channel
    def deliver
      mailer.send(@notification.event, @notification.monitor).deliver_later
      # delivered_at marks "handed to the mail queue" (the alert was dispatched),
      # not "the SMTP server accepted it" — deliver_later enqueues a Solid Queue
      # job that does the actual send with its own retries. That's the right
      # granularity for the transition-only audit log in V1.
      @notification.update!(delivered_at: Time.current)
    end

    private
      def mailer
        MonitorMailer
      end
  end
end
