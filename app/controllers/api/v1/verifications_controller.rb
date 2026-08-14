module Api
  module V1
    # GET /api/v1/verify — a no-op that proves a ping key works (v1-scope §5.5).
    # It is the only honest way to verify the check-in credential end to end: a
    # synthetic "test check-in" would assert a job ran when it never has.
    #
    # A SIBLING of the check-in controller, not a second action on it and not a
    # subclass of Api::V1::BaseController. Sharing the check-in controller would
    # run its per-monitor limiter here with no task key to read, collapsing every
    # verify onto one digest("") bucket per credential; a separate controller gets
    # its own controller_path-scoped buckets, so verify's rejections can never
    # consume the check-in budget.
    class VerificationsController < ActionController::API
      include PingKeyAuthentication

      # No per-monitor layer — there is no task key to key one on — so this is the
      # whole bound, at the same host-wide ceiling as the check-in path.
      rate_limit to: PER_IP_LIMIT, within: PER_IP_WINDOW, name: "per-ip",
                 by: -> { request.remote_ip },
                 with: RATE_LIMITED, store: RATE_LIMIT_STORE

      before_action :authenticate_ping_key!

      # An API key gets the same opaque 401 as a wrong one: this endpoint is the
      # deliberate, sole exception to "the ping key can only check in", and it does
      # not widen to the other credential. Verifying an API key needs no new
      # surface — GET /api/v1/monitors already proves that one.
      #
      # Records nothing. The key's own coarsened last_used_at write still happens
      # inside PingKey.authenticating, and that is all.
      def show
        render json: { ok: true }
      end
    end
  end
end
