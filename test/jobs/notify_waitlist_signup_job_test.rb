require "test_helper"

# Orchestration only: NotifyWaitlistSignupJob loads the WaitlistSignup and
# delegates to WaitlistSignup::SlackAlert (test/models/waitlist_signup/slack_alert_test.rb
# covers the actual delivery behaviour — payload, escaping, timeouts, error handling).
class NotifyWaitlistSignupJobTest < ActiveJob::TestCase
  test "perform loads the waitlist signup and delivers its slack alert" do
    with_slack_enabled do
      signup = WaitlistSignup.create!(email_address: "waiter@example.com")
      request = stub_request(:post, Stablemate::TEST_SLACK_WEBHOOK_URL)
        .with(body: { text: "New Stablemate waitlist signup: #{signup.email_address}" }.to_json)
        .to_return(status: 200, body: "ok")

      NotifyWaitlistSignupJob.perform_now(signup.id)

      assert_requested request
    end
  end
end
