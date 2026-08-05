# Public, unauthenticated ping endpoint. The ping_token *is* the credential, so
# there is no session/CSRF here (it is a machine endpoint hit by cron/curl).
class PingsController < ActionController::Base
  # A forged cross-site POST would still need the secret ping_token. Without this,
  # real POSTs raise InvalidAuthenticityToken in production (forgery protection is
  # disabled in the test env, so request tests miss it).
  skip_forgery_protection

  # Deviation note (CLAUDE.md "say so"): the limiter uses a dedicated in-process
  # MemoryStore rather than the shared Solid Cache. The ping limiter is a coarse
  # abuse bound, not a billing-critical global counter; keeping it in-process
  # avoids putting a cache-DB round-trip on the public hot path. Each worker
  # enforces its own copy of the limit.
  PER_TOKEN_LIMIT  = 30
  PER_TOKEN_WINDOW = 1.minute
  PER_IP_LIMIT     = 300
  PER_IP_WINDOW    = 1.minute
  RATE_LIMIT_STORE = ActiveSupport::Cache::MemoryStore.new

  # The per-token layer answers over-limit with a 429, which does not leak token
  # validity: a scanner already distinguishes 200 vs 404 below the threshold, and
  # above it real and fake tokens both converge to 429. The per-ip layer instead
  # short-circuits to the SAME opaque 404 the unknown-token path returns, so
  # scanning is throttled while staying opaque — and is rejected before any DB
  # lookup.
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

    # `status` (alias `s`) carries the job's exit code — blank/absent/"0" is a
    # success, ANY other value a failure. `status` wins when both spellings are
    # sent. Parsed once per request into locals — two ternaries reading separate
    # helpers invited the predicates to drift apart.
    status  = string_param(:status, :s)
    failure = status.present? && status != "0"

    monitor.check_in!(
      received_at: Time.current,
      kind: failure ? "failure" : "success",
      # A failure without a message still records a non-blank error so the alert
      # is never blank; truncation happens in the model layer.
      error: failure ? string_param(:message, :m) || "exited with status #{status}" : nil,
      source_ip: request.remote_ip,
      duration_ms: numeric_duration_ms
    )

    render json: { ok: true }
  end

  private
    # The widest value the int4 `duration_ms` column can hold. Anything above it
    # raises ActiveModel::RangeError on assignment, and that raise happens INSIDE
    # CheckIn's transaction — so a bad duration would roll back the PingEvent and
    # the contact timestamps too, silently un-registering the ping.
    DURATION_MS_RANGE = 0..2_147_483_647

    # A non-numeric value must become nil, not 0 — String#to_i would silently
    # corrupt latency data — and a value outside the storable range is likewise "no
    # latency measured" rather than a reason to reject the ping: the heartbeat is
    # the payload here, the duration is a nice to have.
    def numeric_duration_ms
      duration = Integer(params[:duration_ms], exception: false)
      duration if DURATION_MS_RANGE.cover?(duration)
    end

    # First present String among aliased params. Only String values count: this is
    # a public endpoint, and bracket-syntax params (?status[]=1, ?status[a]=b)
    # arrive as Array/Parameters — those must be ignored, not stored as stringified
    # garbage.
    def string_param(*names)
      names.map { |name| params[name] }.find { |value| value.is_a?(String) && value.present? }
    end
end
