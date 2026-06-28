module Api
  module V1
    # Base for the bearer-authed JSON API. Resolves the Authorization: Bearer
    # token to an ApiKey (and its owner) via ApiKey.authenticating, which compares
    # in constant time and touches last_used_at. No session/cookie auth here, no
    # CSRF (token-auth JSON, not a browser form). Every action is tenant-scoped to
    # current_user.monitors. Invalid/missing/revoked -> opaque 401. (phase-3 §3.2)
    class BaseController < ActionController::API
      before_action :authenticate_api_key!

      private
        attr_reader :current_user

        def authenticate_api_key!
          @current_api_key = ApiKey.authenticating(bearer_token)
          @current_user = @current_api_key&.user
          render_unauthorized unless @current_user
        end

        # Extract the raw token from `Authorization: Bearer <token>`. Returns nil
        # for any malformed/missing header (mapped to an opaque 401 above).
        def bearer_token
          header = request.authorization.to_s
          header[/\ABearer (.+)\z/, 1]
        end

        def render_unauthorized
          render json: { error: "unauthorized" }, status: :unauthorized
        end

        # Tenant-scoped monitor lookup: a foreign / unknown id raises RecordNotFound
        # which we surface as an opaque 404 (no cross-tenant existence leak).
        def find_monitor
          current_user.monitors.find(params[:id])
        end

        # Map cross-tenant / unknown ids to a 404 without leaking which it was.
        rescue_from ActiveRecord::RecordNotFound do
          render json: { error: "not_found" }, status: :not_found
        end

        # The public ping URL for a monitor, built off the current request host so
        # the gem can hit it directly. (The route helper reads request.host.)
        def ping_url_for(monitor)
          ping_url(monitor.ping_token)
        end

        # Index/sync view of a monitor.
        def monitor_json(monitor)
          {
            id: monitor.id,
            name: monitor.name,
            status: monitor.status,
            registration_key: monitor.registration_key,
            ping_url: ping_url_for(monitor),
            last_ping_at: monitor.last_ping_at,
            next_due_at: monitor.next_due_at
          }
        end

        # Detail view: the index fields plus richer status (interval/grace and,
        # when Phase 2 data exists, the 90-day uptime percent).
        def monitor_detail_json(monitor)
          monitor_json(monitor).merge(
            source: monitor.source,
            expected_interval_seconds: monitor.expected_interval_seconds,
            grace_period_seconds: monitor.grace_period_seconds,
            uptime_percent: monitor.uptime_percent
          )
        end
    end
  end
end
