require "test_helper"

# The shared Slack transport. Every guarantee the team alerts rely on — the
# config gate, mrkdwn escaping, and never raising at the caller — is stated once
# here rather than per alert.
class Slack::WebhookTest < ActiveSupport::TestCase
  test "post sends the message as JSON to the configured webhook" do
    with_slack_enabled do
      request = stub_request(:post, TestCredentials::SLACK_WEBHOOK_URL)
        .with(
          headers: { "Content-Type" => "application/json" },
          body: { text: "Something happened" }.to_json
        )
        .to_return(status: 200, body: "ok")

      Slack::Webhook.new("signup").post("Something happened")

      assert_requested request
    end
  end

  test "post escapes Slack mrkdwn special characters so a value can't become formatting" do
    with_slack_enabled do
      request = stub_request(:post, TestCredentials::SLACK_WEBHOOK_URL)
        .with(body: { text: "New signup: a&lt;b&amp;c&gt;d@example.com" }.to_json)
        .to_return(status: 200, body: "ok")

      Slack::Webhook.new("signup").post("New signup: a<b&c>d@example.com")

      assert_requested request
    end
  end

  test "post is a no-op when Slack is not configured" do
    with_slack_disabled do
      Slack::Webhook.new("signup").post("Something happened")

      assert_not_requested :post, /hooks\.slack\.com/
    end
  end

  test "post logs a non-2xx response under the caller's label instead of treating it as delivered" do
    with_slack_enabled do
      stub_request(:post, TestCredentials::SLACK_WEBHOOK_URL).to_return(status: 404, body: "no_team")

      logs = capturing_logs { Slack::Webhook.new("waitlist").post("Something happened") }

      assert_match(/Slack waitlist alert returned 404/, logs)
    end
  end

  test "post logs and swallows a transport error under the caller's label rather than raising" do
    with_slack_enabled do
      stub_request(:post, TestCredentials::SLACK_WEBHOOK_URL).to_raise(Net::OpenTimeout)

      # The caller must never see this: a Slack outage can't fail a sign-up.
      logs = capturing_logs { Slack::Webhook.new("signup").post("Something happened") }

      assert_match(/Slack signup alert failed/, logs)
    end
  end
end
