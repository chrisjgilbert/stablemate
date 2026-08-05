require "test_helper"

# The alert owns one thing: the sentence it sends. The transport guarantees are
# stated once in test/models/slack/webhook_test.rb.
class User::SignupAlertTest < ActiveSupport::TestCase
  test "deliver! posts a message naming the user to the Slack webhook" do
    with_slack_enabled do
      request = stub_request(:post, TestCredentials::SLACK_WEBHOOK_URL)
        .with(
          headers: { "Content-Type" => "application/json" },
          body: { text: "New Stablemate signup: #{users(:alice).email_address}" }.to_json
        )
        .to_return(status: 200, body: "ok")

      User::SignupAlert.new(users(:alice)).deliver!

      assert_requested request
    end
  end

  # Escaping belongs to the transport, but it is the property a user-supplied
  # value depends on, so it stays pinned end-to-end through the signup path.
  test "deliver! escapes Slack mrkdwn special characters in the email" do
    with_slack_enabled do
      alice = users(:alice)
      alice.update_column(:email_address, "a<b&c>d@example.com")

      request = stub_request(:post, TestCredentials::SLACK_WEBHOOK_URL)
        .with(body: { text: "New Stablemate signup: a&lt;b&amp;c&gt;d@example.com" }.to_json)
        .to_return(status: 200, body: "ok")

      User::SignupAlert.new(alice).deliver!

      assert_requested request
    end
  end
end
