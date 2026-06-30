# Async delivery for User::SignupAlert (mirrors ActionMailer's deliver_later)
# so a Slack hiccup never blocks sign-up. Orchestration only — the actual
# Slack post lives on the operation object, not here.
class NotifySignupJob < ApplicationJob
  queue_as :default

  def perform(user_id)
    User::SignupAlert.new(User.find(user_id)).deliver!
  end
end
