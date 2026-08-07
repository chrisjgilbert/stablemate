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
                       request.authorization.to_s.presence || request.remote_ip
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

          monitor.check_in!(
            received_at: Time.current,
            kind: failure? ? "failure" : "success",
            error: failure? ? reported_error : nil,
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
          # `status` (alias `s`) carries the job's exit code — blank/absent/"0" is
          # a success, ANY other value a failure. `status` wins when both spellings
          # are sent.
          def failure?
            status = string_param(:status, :s)
            status.present? && status != "0"
          end

          # A failure without a message still records a non-blank error so the
          # alert is never blank; truncation happens in the model layer.
          def reported_error
            string_param(:message, :m) || "exited with status #{string_param(:status, :s)}"
          end

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
          def numeric_duration_ms
            duration = Integer(params[:duration_ms], exception: false)
            duration if DURATION_MS_RANGE.cover?(duration)
          end

          # First present String among aliased params. Only String values count:
          # bracket-syntax params (?status[]=1, ?status[a]=b) arrive as
          # Array/Parameters — those must be ignored, not stored as stringified
          # garbage.
          #
          # These three helpers are a deliberate copy of the ones on the public
          # PingsController rather than an extraction: that controller is deleted
          # whole in phase 3, and phase 1 must not touch the path it is still
          # serving.
          def string_param(*names)
            names.map { |name| params[name] }.find { |value| value.is_a?(String) && value.present? }
          end
      end
    end
  end
end
