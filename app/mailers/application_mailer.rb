class ApplicationMailer < ActionMailer::Base
  # A consistent from-domain that matches the SPF/DKIM records (docs/runbook.md) is
  # what keeps these out of spam. Self-hosters override the addresses via
  # STABLEMATE_MAIL_FROM / STABLEMATE_MAIL_REPLY_TO so alerts come from a domain
  # their SMTP authorises; the defaults keep dev/test/CI booting without them set.
  # TODO: switch back to alerts@/support@stablemate.dev once that domain has
  # SPF/DKIM set up — chris@chrisgilbert.dev is a temporary stand-in.
  default from: ENV.fetch("STABLEMATE_MAIL_FROM", %("Stablemate" <chris@chrisgilbert.dev>)),
    reply_to: ENV.fetch("STABLEMATE_MAIL_REPLY_TO", "chris@chrisgilbert.dev")
  layout "mailer"
end
