require "test_helper"

# The alert owns one thing: the sentence it sends. The transport guarantees are
# stated once in test/models/slack/webhook_test.rb.
class WaitlistSignup::SlackAlertTest < ActiveSupport::TestCase
  test "deliver! posts a message naming the email to the Slack webhook" do
    with_slack_enabled do
      signup = WaitlistSignup.create!(email_address: "waiter@example.com")
      request = stub_request(:post, TestCredentials::SLACK_WEBHOOK_URL)
        .with(
          headers: { "Content-Type" => "application/json" },
          body: { text: "New Stablemate waitlist signup: waiter@example.com" }.to_json
        )
        .to_return(status: 200, body: "ok")

      WaitlistSignup::SlackAlert.new(signup).deliver!

      assert_requested request
    end
  end

  # Escaping belongs to the transport, but it is the property a user-supplied
  # value depends on, so it stays pinned end-to-end through the waitlist path.
  test "deliver! escapes Slack mrkdwn special characters in the email" do
    with_slack_enabled do
      signup = WaitlistSignup.new(email_address: "a<b&c>d@example.com")

      request = stub_request(:post, TestCredentials::SLACK_WEBHOOK_URL)
        .with(body: { text: "New Stablemate waitlist signup: a&lt;b&amp;c&gt;d@example.com" }.to_json)
        .to_return(status: 200, body: "ok")

      WaitlistSignup::SlackAlert.new(signup).deliver!

      assert_requested request
    end
  end
end
