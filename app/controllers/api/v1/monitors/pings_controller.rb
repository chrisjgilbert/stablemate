module Api
  module V1
    module Monitors
      # POST /api/v1/monitors/:registration_key/pings — the V1 check-in endpoint
      # (v1-scope §5). The monitor is addressed by its task key and the credential
      # rides an Authorization header, so nothing secret enters the URL (or the
      # logs), and GET cannot trigger a side effect.
      #
      # It does NOT inherit Api::V1::BaseController — see PingKeyAuthentication.
      class PingsController < ActionController::API
        include PingKeyAuthentication

        # The per-monitor ceiling is what bounds a runaway task, and what bounds
        # the alert flood a leaked key can produce. 40 tasks checking in twice a
        # minute under one key pass unthrottled; this is the bound a small app
        # meets first.
        PER_MONITOR_LIMIT  = 30
        PER_MONITOR_WINDOW = 1.minute

        # DECLARATION ORDER IS LOAD-BEARING, and it is the opposite of the obvious
        # one. Each layer increments its own counter unconditionally, but the
        # responder halts the chain by rendering — so the layer that fires first is
        # the only one that charges. Per-IP first and a runaway task's rejections
        # are billed to the shared host-wide bucket, throttling every other tenant
        # behind the same proxy; per-monitor first and they stop at the runaway's
        # own bucket.
        #
        # The per-monitor key is built from values readable BEFORE authentication,
        # because a limiter that reads post-authentication state runs at filter
        # time when the ivar does not exist yet — Rails builds the key with
        # `.compact`, which drops the nil rather than distinguishing it, collapsing
        # the entire controller onto one counter.
        #
        # Both halves are digested. Rails emits `by:` into an
        # ActiveSupport::Notifications payload on every throttle and writes it into
        # the store as the literal cache key, so an undigested key puts live
        # credentials into any broadly-subscribed monitoring tool. Digesting also
        # length-bounds the attacker-chosen task-name half.
        rate_limit to: PER_MONITOR_LIMIT, within: PER_MONITOR_WINDOW, name: "per-monitor",
                   by: -> {
                     credential = Digest::SHA256.hexdigest(
                       request.authorization.to_s.presence || request.remote_ip.to_s
                     )
                     "#{credential}|#{Digest::SHA256.hexdigest(params[:registration_key].to_s)}"
                   },
                   with: RATE_LIMITED, store: RATE_LIMIT_STORE
        rate_limit to: PER_IP_LIMIT, within: PER_IP_WINDOW, name: "per-ip",
                   by: -> { request.remote_ip },
                   with: RATE_LIMITED, store: RATE_LIMIT_STORE

        before_action :authenticate_ping_key!

        def create
          monitor = current_project.monitors.find_by(registration_key: params[:registration_key])
          # find_by and an explicit guard, not find_by!: the contract promises
          # 404 {"error": "not_found"}, and RecordNotFound would answer through the
          # rescue_from above only because one was written — the bang method is one
          # refactor away from an HTML page.
          return render_not_found unless monitor

          # `status` (alias `s`) carries the job's exit code — blank/absent/"0" is
          # a success, ANY other value a failure. `status` wins when both spellings
          # are sent. Parsed once per request into locals: two ternaries reading
          # separate helpers invited the predicates to drift apart, and re-scanning
          # params four times is waste on the hottest path in the system.
          status  = string_param(:status, :s)
          failure = status.present? && status != "0"

          monitor.check_in!(
            received_at: Time.current,
            kind: failure ? "failure" : "success",
            # A failure without a message still records a non-blank error so the
            # alert is never blank; truncation happens in the model layer.
            error: failure ? string_param(:message, :m) || "exited with status #{status}" : nil,
            # request.remote_ip, so its meaning depends on trusted_proxies: this
            # endpoint sits behind kamal-proxy rather than being public.
            source_ip: request.remote_ip,
            duration_ms: numeric_duration_ms
          )

          render json: { ok: true }
        end

        private
          # The body is form-encoded — that is what the gem sends, and what the
          # ready-to-paste curl lines send. (Rails parses a JSON body into the same
          # params, so a JSON client works too; form-encoded is the documented
          # contract.)
          #
          # The widest value the int4 `duration_ms` column can hold. Anything above
          # it raises ActiveModel::RangeError on assignment, and that raise happens
          # INSIDE CheckIn's transaction — so a bad duration would roll back the
          # PingEvent and the contact timestamps too, silently un-registering the
          # ping.
          DURATION_MS_RANGE = 0..2_147_483_647

          # A non-numeric value must become nil, not 0 — String#to_i would silently
          # corrupt latency data — and a value outside the storable range is
          # likewise "no latency measured" rather than a reason to reject the ping:
          # the heartbeat is the payload here, the duration is a nice to have.
          #
          # Base 10 EXPLICITLY: Kernel#Integer honours literal prefixes, so a
          # wrapper formatting its timing with `printf "%04d"` sends `0755` and
          # gets 493 stored — the same silent corruption the paragraph above is
          # about, in the direction it did not guard. A JSON client's number
          # arrives already parsed and skips the string path entirely.
          def numeric_duration_ms
            duration =
              case (raw = params[:duration_ms])
              when Integer then raw
              when Numeric then raw.to_i
              when String  then Integer(raw, 10, exception: false)
              end
            duration if DURATION_MS_RANGE.cover?(duration)
          end

          # First present scalar among aliased params.
          #
          # Strings AND numbers, because this endpoint accepts a JSON body and a
          # JSON exit code is a NUMBER: `{"status": 1}` dropped for not being a
          # String reads as a success, so a job that reported its own failure is
          # monitored as healthy forever. Bracket-syntax params (?status[]=1,
          # ?status[a]=b) arrive as Array/Parameters and are still ignored rather
          # than stored as stringified garbage — that is what this guards.
          #
          # A deliberate copy of the public PingsController's helpers rather than
          # an extraction: that controller is deleted whole in phase 3, and phase 1
          # must not touch the path it is still serving. (It parses only
          # form-encoded bodies in practice, where every value is a String, so the
          # JSON hole above is this controller's alone.)
          SCALAR_PARAM_TYPES = [ String, Numeric ].freeze

          def string_param(*names)
            names.map { |name| params[name] }
                 .find { |value| SCALAR_PARAM_TYPES.any? { |type| value.is_a?(type) } && value.to_s.present? }
                 &.to_s
          end
      end
    end
  end
end
