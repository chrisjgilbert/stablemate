class MonitorMailer < ApplicationMailer
  # Alert: a monitor is down. Cause-aware copy (job-failure-details.md §8):
  #
  #   - missed_ping (and nil, defensively): the ping is overdue — name, what
  #     happened, expected-by time, link to detail.
  #   - reported_error: the job ran and reported a failure — the body leads with
  #     the error text. The subject carries only the monitor name, never the
  #     error (§12-D: headers stay injection-proof, lock-screen previews clean).
  #
  # The incident is passed in (not read off the monitor) so the email is
  # deterministic under deliver_later — open_incident at render time would race
  # a fast recovery.
  def down(monitor, incident: nil)
    @monitor = monitor

    if incident&.cause == "reported_error"
      @error = incident.error
      mail to: monitor.user.email_address,
           subject: "#{monitor.name} reported an error"
    else
      @expected_by = monitor.due_with_grace_at
      mail to: monitor.user.email_address,
           subject: "#{monitor.name} missed its check-in"
    end
  end

  # Alert: a previously-down monitor pinged again and has recovered. Accepts the
  # incident kwarg because EmailChannel passes it to every event, but the
  # recovery copy is cause-agnostic — it is deliberately ignored.
  def recovered(monitor, incident: nil)
    @monitor = monitor

    mail to: monitor.user.email_address,
         subject: "#{monitor.name} is back up"
  end
end
