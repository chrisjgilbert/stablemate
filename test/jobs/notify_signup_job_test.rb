require "test_helper"

# Orchestration only: NotifySignupJob loads the User and delegates to
# User::SignupAlert (test/models/user/signup_alert_test.rb covers the actual
# delivery behaviour — payload, escaping, timeouts, error handling).
class NotifySignupJobTest < ActiveJob::TestCase
  test "perform loads the user and delivers their signup alert" do
    with_slack_enabled do
      alice = users(:alice)
      request = stub_request(:post, Stablemate::TEST_SLACK_WEBHOOK_URL)
        .with(body: { text: "New Stablemate signup: #{alice.email_address}" }.to_json)
        .to_return(status: 200, body: "ok")

      NotifySignupJob.perform_now(alice.id)

      assert_requested request
    end
  end
end
