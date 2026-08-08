module Api
  module V1
    # Base for the bearer-authed JSON API. The key IS the app's identity, so every
    # action is tenant-scoped to current_project.monitors — the opaque-404
    # guarantee is cross-PROJECT. No session/cookie auth here, no CSRF.
    # Invalid/missing/revoked/project-less -> opaque 401.
    class BaseController < ActionController::API
      include ActionController::RateLimiting

      # PER_KEY bounds ONE credential, so a compromised or buggy key can't hammer
      # the sync bulk-write. It is keyed on the caller-supplied token, so an
      # enumerating scanner mints a fresh bucket with every made-up token — PER_IP
      # is what actually caps unauthenticated enumeration, and it runs before
      # authenticate_api_key!, so a scanner is rejected without a DB lookup.
      #
      # Both layers answer over-limit with the same plain 429. The ping endpoint
      # deliberately answers its per-IP layer with an opaque 404 instead, because
      # there the response itself is the oracle; here every auth failure already
      # returns an identical 401 whether or not the token exists, so a 429
      # discloses nothing — and it is what a legitimate client sharing an egress IP
      # needs in order to back off.
      #
      # Dedicated in-process store so both bounds hold under the test env's
      # null_store. Per-process, so the effective ceiling scales with the worker
      # count — a coarse abuse bound, not a global counter.
      PER_KEY_LIMIT  = 120
      PER_KEY_WINDOW = 1.minute
      PER_IP_LIMIT   = 300
      PER_IP_WINDOW  = 1.minute
      RATE_LIMIT_STORE = ActiveSupport::Cache::MemoryStore.new

      RATE_LIMITED = -> { render json: { error: "rate_limited" }, status: :too_many_requests }

      # Digested, because `by:` is not private: Rails writes it into the store as
      # the literal cache key and emits it into an ActiveSupport::Notifications
      # payload on every throttle — so an undigested value puts live credentials
      # into any broadly-subscribed monitoring tool, and into Postgres if this
      # store ever moves to Solid Cache. The bucket identity is unchanged; only
      # its spelling is.
      rate_limit to: PER_KEY_LIMIT, within: PER_KEY_WINDOW, name: "per-key",
                 by: -> {
                   Digest::SHA256.hexdigest(request.authorization.presence || request.remote_ip.to_s)
                 },
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

        # Returns nil for any malformed/missing header (mapped to an opaque 401).
        def bearer_token
          header = request.authorization.to_s
          header[/\ABearer (.+)\z/, 1]
        end

        def render_unauthorized
          render json: { error: "unauthorized" }, status: :unauthorized
        end

        # A monitor in another project (even the same user's) or an unknown id
        # raises RecordNotFound, surfaced as an opaque 404 below — no cross-project
        # existence leak.
        def find_monitor
          current_project.monitors.find(params[:id])
        end

        rescue_from ActiveRecord::RecordNotFound do
          render json: { error: "not_found" }, status: :not_found
        end

        def ping_url_for(monitor)
          ping_url(monitor.ping_token)
        end

        # The shape lives on the presenter; this controller only supplies the
        # request-dependent ping URL.
        def present(monitor)
          MonitorPresenter.new(monitor, ping_url: ping_url_for(monitor))
        end
    end
  end
end
