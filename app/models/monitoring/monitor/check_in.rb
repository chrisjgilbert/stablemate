module Monitoring
  class Monitor
    # Record a single successful ping, reached via `monitor.check_in!(...)`.
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

          @monitor.register_contact(received_at)

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
            # Record the event but never transition or alert: the monitor is
            # deliberately not monitored, so a stray ping must not silently resume
            # it. For `suspended` this also guards the billing cap — reactivating
            # here would let a downgraded over-cap user monitor for free just by
            # continuing to ping.
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
          # If somehow there is no open incident, still flip to up but emit NO
          # recovery alert — "exactly one recovered email on resolution" means no
          # incident-less recovery emails (spec §3.7).
          resolved = @monitor.open_incident
          return nil unless resolved

          resolved.resolve!(at: received_at)
          # Backstop for an anomalous state — an open incident that somehow already
          # carries a recovered notification — so the public ping path returns 200
          # rather than a 500 from the partial unique index on (incident_id, event).
          return nil if @monitor.notifications.exists?(incident: resolved, event: "recovered")

          @monitor.notifications.create!(
            incident: resolved,
            channel: "email",
            event: "recovered"
          )
        end
    end
  end
end
