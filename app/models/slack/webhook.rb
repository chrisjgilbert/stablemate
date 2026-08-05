module Slack
  # Post a plain-text message to the team's Slack incoming webhook. `label` names
  # the alert in our own logs ("signup", "waitlist").
  #
  # Its own namespace rather than Notifications::, which is the monitor-alert
  # Command subsystem (Dispatch → Channel → EmailChannel) dispatching off a
  # persisted Notification with a required belongs_to :monitor. A sign-up isn't a
  # monitor event, and that namespace is reserved for the V2 webhook channel.
  #
  # Delivery errors (including a non-2xx response) are logged, never raised, so a
  # Slack outage can never fail the sign-up that triggered it. A no-op unless
  # SLACK_WEBHOOK_URL is configured, so self-hosters never see it.
  class Webhook
    TIMEOUT = 5 # seconds — keeps a hung Slack endpoint from tying up a job worker

    def initialize(label)
      @label = label
    end

    # Escapes the whole message rather than asking each caller to escape what it
    # interpolates: every message is prose plus a user-supplied value, so the two
    # are equivalent — and escaping at the boundary can't be forgotten.
    def post(text)
      return unless Stablemate.slack_notifications_enabled?

      uri = URI(Stablemate.slack_webhook_url)
      response = Net::HTTP.start(uri.host, uri.port,
        use_ssl: uri.scheme == "https", open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
        http.post(uri.request_uri, { text: escape(text) }.to_json, "Content-Type" => "application/json")
      end

      Rails.logger.error("Slack #{@label} alert returned #{response.code}") unless response.is_a?(Net::HTTPSuccess)
    rescue StandardError => e
      Rails.logger.error("Slack #{@label} alert failed: #{e.class}: #{e.message}")
    end

    private
      # Slack mrkdwn treats &, <, > specially (e.g. <url|label> renders a link);
      # escape them so an email address can never be interpreted as formatting.
      # https://api.slack.com/reference/surfaces/formatting#escaping
      def escape(text)
        text.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
      end
  end
end
