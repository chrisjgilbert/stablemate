class ApplicationMailer < ActionMailer::Base
  # A configured, human "from" + matching reply-to. A consistent from-domain that
  # matches the SPF/DKIM records (docs/runbook.md) is what keeps these out of
  # spam. (phase-4 §3.4)
  default from: %("Stablemate" <alerts@stablemate.dev>),
          reply_to: "support@stablemate.dev"
  layout "mailer"
end
