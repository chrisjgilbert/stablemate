class ApplicationMailer < ActionMailer::Base
  default from: "alerts@stablemate.dev"
  layout "mailer"
end
