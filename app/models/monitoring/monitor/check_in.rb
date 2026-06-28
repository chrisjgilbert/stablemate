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
    #      - paused        : record the event + timestamps but DO NOT change
    #                       status or alert — paused means "don't monitor". The
    #                       user explicitly stopped monitoring, so a stray ping
    #                       must not silently resume it. (Pinned by a test.)
    #   3. broadcast a Turbo Stream badge/row update over Solid Cable.
    class CheckIn
      def initialize(monitor)
        @monitor = monitor
      end

      def call(received_at: Time.current, source_ip: nil, duration_ms: nil)
        recovered_notification = nil

        @monitor.transaction do
          @monitor.ping_events.create!(
            received_at:,
            kind: "success",
            source_ip:,
            duration_ms:
          )

          @monitor.last_ping_at = received_at
          @monitor.next_due_at  = next_due_from(received_at)

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
          when "paused"
            nil # paused stays paused: record the event, no transition, no alert.
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
