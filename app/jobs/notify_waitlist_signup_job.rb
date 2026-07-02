# Async delivery for WaitlistSignup::SlackAlert (mirrors NotifySignupJob) so a
# Slack hiccup never blocks joining the waitlist.
class NotifyWaitlistSignupJob < ApplicationJob
  queue_as :default

  def perform(waitlist_signup_id)
    WaitlistSignup::SlackAlert.new(WaitlistSignup.find(waitlist_signup_id)).deliver!
  end
end
