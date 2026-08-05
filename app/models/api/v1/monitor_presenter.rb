module Api
  module V1
    # The JSON representation of a monitor on the /api/v1 surface.
    #
    # Both shapes lived on Api::V1::BaseController, reading eleven monitor
    # attributes between them and no controller state — which gave that class two
    # unrelated reasons to change: the auth and rate-limiting policy, and the shape
    # of the API's payloads.
    #
    # `ping_url` is injected because building it needs the request host, which only
    # the controller has (BaseController#ping_url_for, also used by the sync and
    # rotate endpoints for their own payloads).
    class MonitorPresenter
      def initialize(monitor, ping_url:)
        @monitor = monitor
        @ping_url = ping_url
      end

      # Index view. (The sync endpoint publishes its own deliberately smaller
      # payload for old-gem back-compat and does not come through here.)
      def summary
        {
          id: @monitor.id,
          name: @monitor.name,
          status: @monitor.status,
          registration_key: @monitor.registration_key,
          ping_url: @ping_url,
          last_ping_at: @monitor.last_ping_at,
          next_due_at: @monitor.next_due_at
        }
      end

      # Detail view: the index fields plus interval/grace and the 90-day uptime.
      def detail
        summary.merge(
          source: @monitor.source,
          expected_interval_seconds: @monitor.expected_interval_seconds,
          grace_period_seconds: @monitor.grace_period_seconds,
          uptime_percent: @monitor.uptime_percent
        )
      end
    end
  end
end
