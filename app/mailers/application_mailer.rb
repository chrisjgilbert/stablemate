class ApplicationMailer < ActionMailer::Base
  # A configured, human "from" + matching reply-to. A consistent from-domain that
  # matches the SPF/DKIM records (docs/runbook.md) is what keeps these out of
  # spam. (phase-4 §3.4) Self-hosters override the addresses via STABLEMATE_MAIL_FROM
  # / STABLEMATE_MAIL_REPLY_TO so alerts come from a domain their SMTP authorises.
  default from: ENV.fetch("STABLEMATE_MAIL_FROM"),
    reply_to: ENV.fetch("STABLEMATE_MAIL_REPLY_TO")
  layout "mailer"
end
