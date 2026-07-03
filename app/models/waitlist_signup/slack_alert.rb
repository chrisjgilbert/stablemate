# Operation: post a Slack message to the team when someone joins the launch
# waitlist. Mirrors User::SignupAlert — same config gate, same webhook, same
# swallow-errors-never-raise contract (a Slack outage can never fail a
# waitlist join).
class WaitlistSignup::SlackAlert
  TIMEOUT = 5 # seconds — keeps a hung Slack endpoint from tying up a job worker

  def initialize(waitlist_signup)
    @waitlist_signup = waitlist_signup
  end

  def deliver!
    return unless Stablemate.slack_notifications_enabled?

    uri = URI(Stablemate.slack_webhook_url)
    response = Net::HTTP.start(uri.host, uri.port,
      use_ssl: uri.scheme == "https", open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
      http.post(uri.request_uri, payload.to_json, "Content-Type" => "application/json")
    end

    Rails.logger.error("Slack waitlist alert returned #{response.code}") unless response.is_a?(Net::HTTPSuccess)
  rescue StandardError => e
    Rails.logger.error("Slack waitlist alert failed: #{e.class}: #{e.message}")
  end

  private
    def payload
      { text: "New Stablemate waitlist signup: #{escape(@waitlist_signup.email_address)}" }
    end

    # Slack mrkdwn treats &, <, > specially (e.g. <url|label> renders a
    # link); escape them so an email address can never be interpreted as
    # formatting. https://api.slack.com/reference/surfaces/formatting#escaping
    def escape(text)
      text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
    end
end
