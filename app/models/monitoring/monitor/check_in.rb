module Monitoring
  class Monitor
    # Operation object: record a single ping for a monitor.
    #
    # Reached via `monitor.check_in!(...)`. Full Phase 1 form:
    #   1. create a success PingEvent, advance last_ping_at / next_due_at;
    #   2. transition by current status:
    #      - pending -> up;
    #      - down    -> up: resolve the open incident, create + dispatch a
    #                       `recovered` Notification;
    #      - up      -> up: timestamps only, no alert (no per-ping noise);
    #      - paused/
    #        suspended     : record the event + timestamps but DO NOT change
    #                       status or alert — both mean "don't monitor" (user-paused
    #                       or plan-suspended), so a stray ping must not silently
    #                       resume it. For `suspended` this also guards the billing
    #                       cap. (Pinned by tests.)
    #   3. broadcast a Turbo Stream badge/row update over Solid Cable.
    class CheckIn
      def initialize(monitor)
        @monitor = monitor
      end

      def check_in!(received_at: Time.current, source_ip: nil, duration_ms: nil)
        recovered_notification = nil

        # with_lock reloads under SELECT ... FOR UPDATE so the transition reads
        # fresh status: two recovery pings on the same down monitor serialise, and
        # only the first resolves the incident + emits the recovered alert.
        @monitor.with_lock do
          @monitor.ping_events.create!(
            received_at:,
            kind: "success",
            source_ip:,
            duration_ms:
          )

          @monitor.last_ping_at = received_at
          @monitor.next_due_at  = next_due_from(received_at)
          # Record the first ping once, as the floor for uptime measurement (WU-10):
          # days before it are no-data, never phantom-up. Never moved afterward.
          @monitor.first_ping_at ||= received_at

          recovered_notification = apply_transition(received_at)
          @monitor.save!
        end

        Notifications::Dispatch.new(recovered_notification).deliver if recovered_notification
        @monitor.broadcast_status_update
        @monitor
      end

      private
        # Returns a `recovered` Notification to dispatch (down -> up only), else nil.
        def apply_transition(received_at)
          case @monitor.status
          when "paused", "suspended"
            # paused/suspended record the event but never transition or alert: the
            # monitor is deliberately not monitored (user-paused or plan-suspended),
            # so a stray ping must not silently resume it. For `suspended` this also
            # guards the billing cap — reactivating here would let a downgraded
            # over-cap user monitor for free just by continuing to ping.
            nil
          when "down"
            recover(received_at)
          else # pending or up
            @monitor.status = "up"
            nil
          end
        end

        def recover(received_at)
          @monitor.status = "up"
          # Resolve the open incident (the open-incident invariant means there is
          # at most one) and attach the recovered Notification to *that* incident.
          # If somehow there is no open incident, still flip to up but emit NO
          # recovery alert — "exactly one recovered email on resolution" means no
          # incident-less recovery emails (spec §3.7). Returns the notification to
          # dispatch, or nil.
          resolved = @monitor.open_incident
          return nil unless resolved

          resolved.resolve!(at: received_at)
          # Concurrent recoveries are already serialised by with_lock (the second
          # caller finds no open incident and returns above). This guard is the
          # backstop for an anomalous state — an open incident that somehow already
          # carries a recovered notification — so the public ping path returns 200
          # rather than a 500 from the partial unique index on (incident_id, event).
          return nil if @monitor.notifications.exists?(incident: resolved, event: "recovered")

          @monitor.notifications.create!(
            incident: resolved,
            channel: "email",
            event: "recovered"
          )
        end

        def next_due_from(received_at)
          return nil if @monitor.expected_interval_seconds.blank?

          received_at + @monitor.expected_interval_seconds.seconds
        end
    end
  end
end
