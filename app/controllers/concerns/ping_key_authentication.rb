# Bearer authentication for the two ping-key controllers — the check-in endpoint
# and the verify endpoint (v1-scope §5.2, §5.5).
#
# Deliberately a CONCERN and not a base class, and deliberately not
# Api::V1::BaseController: that base authenticates an ApiKey, so a controller
# inheriting it would have to suppress `before_action :authenticate_api_key!` —
# and suppression can be forgotten. Including a module that only ever looks at
# ping_keys cannot go wrong the same way.
#
# It carries the whole JSON response contract too, because none of it can be
# inherited: the error shapes, the rescue_from, and the rate-limit responder.
# That last one is reached by OMITTING code rather than writing it — Rails 8.1's
# default `with:` raises TooManyRequests, which leaves the controller entirely and
# is dressed by PublicExceptions: a form-encoded request with no Accept header
# (which is exactly what the gem sends) then gets 429 text/html with an EMPTY
# BODY. Hence RATE_LIMITED, and hence the §12 test that asserts the body.
#
# What each including controller must declare for itself: its own `rate_limit`
# lines and its own `before_action :authenticate_ping_key!`, in that order. The
# limiters have to run BEFORE authentication (that is what bounds an
# unauthenticated flood without a database lookup), and a filter declared inside
# `included do` would land ahead of the controller's own — so the ordering is
# stated at each call site where it can be read.
module PingKeyAuthentication
  extend ActiveSupport::Concern

  # Rails resolves a limiter's scope from `controller_path` at filter time, so
  # each including controller gets its OWN buckets out of this shared store —
  # which is why verify is a sibling controller rather than a second action here,
  # and why its rejections cannot consume the check-in controller's budget.
  RATE_LIMIT_STORE = ActiveSupport::Cache::MemoryStore.new

  RATE_LIMITED = -> { render json: { error: "rate_limited" }, status: :too_many_requests }

  # The host-wide bound. The app and its job workers sit behind one proxy, so this
  # is the MACHINE's total check-in budget, not one process's — and behind
  # Cloudflare it collapses to a handful of buckets unless
  # STABLEMATE_BEHIND_CLOUDFLARE is set so trusted_proxies is configured.
  PER_IP_LIMIT  = 300
  PER_IP_WINDOW = 1.minute

  included do
    include ActionController::RateLimiting

    # ActionController::API has no forgery protection to forget, unlike
    # ActionController::Base — which would reintroduce the trap the public
    # PingsController documents, invisible in the test environment.
    rescue_from ActiveRecord::RecordNotFound do
      render json: { error: "not_found" }, status: :not_found
    end

    # Without this an ActionController::API controller answers a full HTML Rails
    # error page. The gem classifies 422 as transient and absorbs it in the grace
    # period, so the monitor then goes down with an email saying it MISSED its
    # check-in — a server-side fault reaching the user as their job failing.
    rescue_from ActiveRecord::RecordInvalid do
      render json: { error: "unprocessable_entity" }, status: :unprocessable_entity
    end
  end

  private
    attr_reader :current_project

    def authenticate_ping_key!
      @current_ping_key = PingKey.authenticating(bearer_token)
      @current_project = @current_ping_key&.project
      render_unauthorized unless @current_project
    end

    # Returns nil for any malformed/missing header (mapped to an opaque 401).
    def bearer_token
      request.authorization.to_s[/\ABearer (.+)\z/, 1]
    end

    def render_unauthorized
      render json: { error: "unauthorized" }, status: :unauthorized
    end

    def render_not_found
      render json: { error: "not_found" }, status: :not_found
    end
end
