class User
  # Post a Slack message to the team when this user has just signed up. Delivery
  # errors (including a non-2xx response) are logged, never raised, so a Slack
  # outage can never fail a sign-up.
  #
  # Deliberately a plain HTTP POST rather than the Notifications::Channel Command
  # pattern: that system dispatches off a persisted Notification row with a
  # required belongs_to :monitor, and a sign-up isn't a monitor event.
  class SignupAlert
    TIMEOUT = 5 # seconds — keeps a hung Slack endpoint from tying up a job worker

    def initialize(user)
      @user = user
    end

    def deliver!
      return unless Stablemate.slack_notifications_enabled?

      uri = URI(Stablemate.slack_webhook_url)
      response = Net::HTTP.start(uri.host, uri.port,
        use_ssl: uri.scheme == "https", open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
        http.post(uri.request_uri, payload.to_json, "Content-Type" => "application/json")
      end

      Rails.logger.error("Slack signup alert returned #{response.code}") unless response.is_a?(Net::HTTPSuccess)
    rescue StandardError => e
      Rails.logger.error("Slack signup alert failed: #{e.class}: #{e.message}")
    end

    private
      def payload
        { text: "New Stablemate signup: #{escape(@user.email_address)}" }
      end

      # Slack mrkdwn treats &, <, > specially (e.g. <url|label> renders a link);
      # escape them so an email address can never be interpreted as formatting.
      # https://api.slack.com/reference/surfaces/formatting#escaping
      def escape(text)
        text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
      end
  end
end
