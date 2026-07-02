require "test_helper"

class WaitlistSignup::SlackAlertTest < ActiveSupport::TestCase
  test "deliver! posts a message naming the email to the Slack webhook" do
    with_slack_enabled do
      signup = WaitlistSignup.create!(email_address: "waiter@example.com")
      request = stub_request(:post, Stablemate::TEST_SLACK_WEBHOOK_URL)
        .with(
          headers: { "Content-Type" => "application/json" },
          body: { text: "New Stablemate waitlist signup: waiter@example.com" }.to_json
        )
        .to_return(status: 200, body: "ok")

      WaitlistSignup::SlackAlert.new(signup).deliver!

      assert_requested request
    end
  end

  test "deliver! is a no-op when Slack is not configured" do
    with_slack_disabled do
      signup = WaitlistSignup.create!(email_address: "waiter@example.com")

      WaitlistSignup::SlackAlert.new(signup).deliver!

      assert_not_requested :post, /hooks\.slack\.com/
    end
  end

  test "deliver! escapes Slack mrkdwn special characters in the email" do
    with_slack_enabled do
      signup = WaitlistSignup.new(email_address: "a<b&c>d@example.com")

      request = stub_request(:post, Stablemate::TEST_SLACK_WEBHOOK_URL)
        .with(body: { text: "New Stablemate waitlist signup: a&lt;b&amp;c&gt;d@example.com" }.to_json)
        .to_return(status: 200, body: "ok")

      WaitlistSignup::SlackAlert.new(signup).deliver!

      assert_requested request
    end
  end

  test "deliver! logs a non-2xx response instead of treating it as delivered" do
    with_slack_enabled do
      signup = WaitlistSignup.create!(email_address: "waiter@example.com")
      stub_request(:post, Stablemate::TEST_SLACK_WEBHOOK_URL).to_return(status: 404, body: "no_team")

      out = StringIO.new
      old_logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(out)
      begin
        WaitlistSignup::SlackAlert.new(signup).deliver!
      ensure
        Rails.logger = old_logger
      end

      assert_match(/Slack waitlist alert returned 404/, out.string)
    end
  end

  test "deliver! logs and swallows the error instead of raising when the request fails" do
    with_slack_enabled do
      signup = WaitlistSignup.create!(email_address: "waiter@example.com")
      stub_request(:post, Stablemate::TEST_SLACK_WEBHOOK_URL).to_raise(Net::OpenTimeout)

      out = StringIO.new
      old_logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(out)
      begin
        WaitlistSignup::SlackAlert.new(signup).deliver!
      ensure
        Rails.logger = old_logger
      end

      assert_match(/Slack waitlist alert failed/, out.string)
    end
  end
end
