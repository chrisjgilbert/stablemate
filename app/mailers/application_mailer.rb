class ApplicationMailer < ActionMailer::Base
  # A configured, human "from" + matching reply-to. A consistent from-domain that
  # matches the SPF/DKIM records (docs/runbook.md) is what keeps these out of
  # spam. (phase-4 §3.4) Self-hosters override the addresses via STABLEMATE_MAIL_FROM
  # / STABLEMATE_MAIL_REPLY_TO so alerts come from a domain their SMTP authorises.
  # A default keeps dev/test/CI booting without the vars set; production overrides
  # both via config/deploy.yml's env passthrough. (phase-4 §3.4)
  # TODO: switch back to alerts@/support@stablemate.dev once that domain has
  # SPF/DKIM set up — chris@chrisgilbert.dev is a temporary stand-in.
  default from: ENV.fetch("STABLEMATE_MAIL_FROM", %("Stablemate" <chris@chrisgilbert.dev>)),
    reply_to: ENV.fetch("STABLEMATE_MAIL_REPLY_TO", "chris@chrisgilbert.dev")
  layout "mailer"
end
