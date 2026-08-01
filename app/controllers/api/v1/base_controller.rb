module Api
  module V1
    # Base for the bearer-authed JSON API. Resolves the Authorization: Bearer
    # token to an ApiKey and its PROJECT (Design B, projects.md §5/§9) via
    # ApiKey.authenticating, which compares in constant time and touches
    # last_used_at. The key IS the app's identity, so every action is tenant-scoped
    # to current_project.monitors — the opaque-404 guarantee is now cross-PROJECT.
    # No session/cookie auth here, no CSRF (token-auth JSON, not a browser form).
    # Invalid/missing/revoked/project-less -> opaque 401. (phase-3 §3.2)
    class BaseController < ActionController::API
      include ActionController::RateLimiting

      # --- Rate limiting (WU-9) ------------------------------------------------
      # Two layers, both generous enough never to throttle a healthy gem cadence:
      #
      #   PER_KEY — bounds ONE credential, so a compromised or buggy key can't
      #     hammer the sync bulk-write. Keyed on the presented token, which is
      #     caller-supplied: an enumerating scanner mints a fresh bucket with
      #     every made-up token, so this layer alone bounds nobody who isn't
      #     re-presenting the same header (M10).
      #   PER_IP  — bounds the whole client whatever it presents, which is what
      #     actually caps unauthenticated enumeration. It runs before
      #     authenticate_api_key!, so a scanner is rejected without a DB lookup.
      #
      # Both layers answer over-limit with the same plain 429 + {"error":
      # "rate_limited"}. The ping endpoint deliberately answers its per-IP layer
      # with the opaque 404 instead, because there the response itself is the
      # oracle (200 vs 404 distinguishes a real token); here every auth failure
      # already returns an identical 401 whether or not the token exists, so a 429
      # discloses nothing about token validity — it only says "this IP is
      # throttled". An honest, documented 429 is also what a legitimate client
      # sharing an egress IP needs in order to back off; a fake 401 would send the
      # gem down the "your key is broken" path instead.
      #
      # Dedicated in-process store so both bounds hold under the test env's
      # null_store (mirrors PingsController).
      #
      # NOTE: the store is per-process, so the effective ceiling scales with the
      # worker count (limit x processes). That's a coarse abuse bound, not a global
      # counter — acceptable here (and consistent with the ping limiter); a truly
      # global bound would key off the shared Solid Cache instead.
      PER_KEY_LIMIT  = 120
      PER_KEY_WINDOW = 1.minute
      PER_IP_LIMIT   = 300
      PER_IP_WINDOW  = 1.minute
      RATE_LIMIT_STORE = ActiveSupport::Cache::MemoryStore.new

      RATE_LIMITED = -> { render json: { error: "rate_limited" }, status: :too_many_requests }

      rate_limit to: PER_KEY_LIMIT, within: PER_KEY_WINDOW, name: "per-key",
                 by: -> { request.authorization.presence || request.remote_ip },
                 with: RATE_LIMITED, store: RATE_LIMIT_STORE
      rate_limit to: PER_IP_LIMIT, within: PER_IP_WINDOW, name: "per-ip",
                 by: -> { request.remote_ip },
                 with: RATE_LIMITED, store: RATE_LIMIT_STORE

      before_action :authenticate_api_key!

      private
        attr_reader :current_project

        def authenticate_api_key!
          @current_api_key = ApiKey.authenticating(bearer_token)
          @current_project = @current_api_key&.project
          render_unauthorized unless @current_project
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

        # Project-scoped monitor lookup: a monitor in another project (even the same
        # user's) or an unknown id raises RecordNotFound, surfaced as an opaque 404
        # (no cross-project existence leak).
        def find_monitor
          current_project.monitors.find(params[:id])
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
