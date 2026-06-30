require "test_helper"

class User::SignupAlertTest < ActiveSupport::TestCase
  test "deliver! posts a message naming the user to the Slack webhook" do
    with_slack_enabled do
      request = stub_request(:post, Stablemate::TEST_SLACK_WEBHOOK_URL)
        .with(
          headers: { "Content-Type" => "application/json" },
          body: { text: "New Stablemate signup: #{users(:alice).email_address}" }.to_json
        )
        .to_return(status: 200, body: "ok")

      User::SignupAlert.new(users(:alice)).deliver!

      assert_requested request
    end
  end

  test "deliver! is a no-op when Slack is not configured" do
    with_slack_disabled do
      User::SignupAlert.new(users(:alice)).deliver!

      assert_not_requested :post, /hooks\.slack\.com/
    end
  end

  test "deliver! escapes Slack mrkdwn special characters in the email" do
    with_slack_enabled do
      alice = users(:alice)
      alice.update_column(:email_address, "a<b&c>d@example.com")

      request = stub_request(:post, Stablemate::TEST_SLACK_WEBHOOK_URL)
        .with(body: { text: "New Stablemate signup: a&lt;b&amp;c&gt;d@example.com" }.to_json)
        .to_return(status: 200, body: "ok")

      User::SignupAlert.new(alice).deliver!

      assert_requested request
    end
  end

  test "deliver! logs a non-2xx response instead of treating it as delivered" do
    with_slack_enabled do
      stub_request(:post, Stablemate::TEST_SLACK_WEBHOOK_URL).to_return(status: 404, body: "no_team")

      out = StringIO.new
      old_logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(out)
      begin
        User::SignupAlert.new(users(:alice)).deliver!
      ensure
        Rails.logger = old_logger
      end

      assert_match(/Slack signup alert returned 404/, out.string)
    end
  end

  test "deliver! logs and swallows the error instead of raising when the request fails" do
    with_slack_enabled do
      stub_request(:post, Stablemate::TEST_SLACK_WEBHOOK_URL).to_raise(Net::OpenTimeout)

      out = StringIO.new
      old_logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(out)
      begin
        User::SignupAlert.new(users(:alice)).deliver!
      ensure
        Rails.logger = old_logger
      end

      assert_match(/Slack signup alert failed/, out.string)
    end
  end
end
