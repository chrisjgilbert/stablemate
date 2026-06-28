# Public, unauthenticated ping endpoint. The ping_token *is* the credential, so
# there is no session/CSRF here (it is a machine endpoint hit by cron/curl).
# Thin: it finds the monitor by token and delegates to monitor.check_in!.
class PingsController < ActionController::Base
  # This is a token-authenticated machine endpoint (cron/curl), not a browser
  # form, so CSRF protection does not apply — a forged cross-site POST would
  # still need the secret ping_token, which is the actual credential. Without
  # this, real POSTs raise InvalidAuthenticityToken (forgery protection is
  # on in production but disabled in the test env, so request tests miss it).
  skip_forgery_protection

  # --- Rate limiting (phase-4 §3.3) ----------------------------------------
  # Two layers, both generous enough never to throttle a legitimate cron (the
  # tightest sane cadence is once a minute; retries/jitter add a few more), but
  # bounding a misconfigured tight loop and token-enumeration scanning.
  #
  #   PER_TOKEN — caps a single monitor's ping rate (a runaway loop on one job).
  #   PER_IP    — caps all ping attempts from one IP (a scanner trying many
  #               tokens), so unknown-token enumeration is also bounded.
  #
  # Deviation note (CLAUDE.md "say so"): the limiter uses a dedicated in-process
  # MemoryStore rather than the shared Solid Cache. The ping limiter is a coarse
  # abuse bound, not a billing-critical global counter; keeping it in-process
  # avoids putting a cache-DB round-trip on the public hot path, and per-process
  # bounding is sufficient to absorb a runaway loop / scan. (Each worker enforces
  # its own copy of the limit.)
  PER_TOKEN_LIMIT  = 30
  PER_TOKEN_WINDOW = 1.minute
  PER_IP_LIMIT     = 300
  PER_IP_WINDOW    = 1.minute
  RATE_LIMIT_STORE = ActiveSupport::Cache::MemoryStore.new

  # Two layers, both backed by RATE_LIMIT_STORE and applied before #create:
  #
  #   per-token — a runaway loop on one monitor. Over-limit → 429. This does not
  #     leak token validity: a scanner already distinguishes 200 vs 404 below the
  #     threshold, and above it real and fake tokens both converge to 429.
  #   per-ip — token-enumeration / scanning from one IP. Over-limit short-circuits
  #     to the SAME opaque 404 the unknown-token path returns (phase-4 §3.3: "still
  #     return 404, no leak, no enumeration signal"), rejecting the request early
  #     without even a DB lookup. So scanning is throttled while staying opaque.
  rate_limit to: PER_TOKEN_LIMIT, within: PER_TOKEN_WINDOW,
             by: -> { params[:ping_token] }, name: "per-token",
             store: RATE_LIMIT_STORE
  rate_limit to: PER_IP_LIMIT, within: PER_IP_WINDOW,
             by: -> { request.remote_ip }, name: "per-ip",
             with: -> { head :not_found }, store: RATE_LIMIT_STORE

  def create
    monitor = Monitoring::Monitor.find_by(ping_token: params[:ping_token])

    # Opaque 404 on an unknown token — no tenant leakage, no "not found" detail.
    return head :not_found unless monitor

    monitor.check_in!(
      received_at: Time.current,
      source_ip: request.remote_ip,
      duration_ms: numeric_duration_ms
    )

    render json: { ok: true }
  end

  private
    # Store a duration only when the param is actually numeric; a non-numeric
    # value (e.g. ?duration_ms=abc) must become nil, not 0 — String#to_i would
    # silently corrupt latency data.
    def numeric_duration_ms
      Integer(params[:duration_ms], exception: false)
    end
end
