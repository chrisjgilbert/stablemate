# Async delivery for User::SignupAlert so a Slack hiccup never blocks sign-up.
class NotifySignupJob < ApplicationJob
  queue_as :default

  def perform(user_id)
    User::SignupAlert.new(User.find(user_id)).deliver!
  end
end
