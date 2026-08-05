# Post a Slack message to the team when someone joins the launch waitlist.
# Mirrors User::SignupAlert — both hold the same Slack::Webhook and differ only
# in this sentence.
class WaitlistSignup::SlackAlert
  def initialize(waitlist_signup)
    @waitlist_signup = waitlist_signup
  end

  def deliver!
    Slack::Webhook.new("waitlist")
      .post("New Stablemate waitlist signup: #{@waitlist_signup.email_address}")
  end
end
