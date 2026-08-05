class User
  # Post a Slack message to the team when this user has just signed up. The
  # transport — config gate, escaping, timeouts, never raising — is Slack::Webhook,
  # shared with the waitlist alert, which differs only in this sentence.
  class SignupAlert
    def initialize(user)
      @user = user
    end

    def deliver!
      Slack::Webhook.new("signup").post("New Stablemate signup: #{@user.email_address}")
    end
  end
end
