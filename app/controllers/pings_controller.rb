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
