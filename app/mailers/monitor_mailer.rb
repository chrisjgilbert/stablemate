class MonitorMailer < ApplicationMailer
  # The subject carries only the monitor name, never the error text — headers stay
  # injection-proof and lock-screen previews clean.
  #
  # The incident is passed in (not read off the monitor) so the email is
  # deterministic under deliver_later — open_incident at render time would race a
  # fast recovery.
  def down(monitor, incident: nil)
    @monitor = monitor
    # ONE discriminator, cause-derived, shared by subject and templates — the
    # templates branch on @reported_error too, never on @error presence, so subject
    # and body can't disagree about which alert this is.
    @reported_error = incident&.reported_error?

    if @reported_error
      @error = incident.error
      subject = "#{monitor.name} reported an error"
    else
      # The incident's start IS the moment the ping was declared overdue, frozen at
      # enqueue time. Reading due_with_grace_at off the live monitor here could cite
      # a FUTURE time: a failure ping on an already-down monitor advances
      # next_due_at while this email sits in the deliver_later queue.
      @expected_by = incident&.started_at || monitor.due_with_grace_at
      subject = "#{monitor.name} missed its check-in"
    end

    mail to: monitor.user.email_address, subject:
  end

  # Accepts the incident kwarg because EmailChannel passes it to every event, but
  # the recovery copy is cause-agnostic — it is deliberately ignored.
  def recovered(monitor, incident: nil)
    @monitor = monitor

    mail to: monitor.user.email_address,
         subject: "#{monitor.name} is back up"
  end
end
