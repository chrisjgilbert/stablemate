module Monitoring
  class Monitor
    # Operation object: record a reported-failure ping — "I ran, but I failed"
    # (job-failure-details.md §5). Reached via monitor.check_in!(kind: "failure").
    # Structurally CheckIn's sibling with MissedPing's incident half:
    #
    #   1. create a failure PingEvent carrying the (truncated) error, advance
    #      last_ping_at / next_due_at — the job DID run, the next run is still
    #      expected on cadence (and `detectable` only scans `up` monitors, so
    #      no double-alert path exists);
    #   2. transition by current status:
    #      - up/pending -> down: open an Incident(cause: "reported_error")
    #                       carrying the error, create + dispatch a `down`
    #                       Notification. No grace — an explicit failure is a
    #                       positive statement, not uncertainty of absence;
    #      - down          : record the event only — no new incident, no email;
    #                       the open incident keeps its original cause/error
    #                       (§5.1: one email in, one email out, per incident);
    #      - paused/
    #        suspended     : record the event but DO NOT change status or alert —
    #                       exactly CheckIn's rule for a deliberately-unmonitored
    #                       monitor.
    #   3. broadcast a Turbo Stream badge/row update over Solid Cable.
    class FailureReport
      def initialize(monitor)
        @monitor = monitor
      end

      def report_failure!(received_at: Time.current, error: nil, source_ip: nil, duration_ms: nil)
        down_notification = nil
        # The model layer owns BOTH text bounds (§6, §10), so every caller —
        # ping endpoint, console, future channels — shares them: truncation to
        # ERROR_MESSAGE_LIMIT, and a stub when no error text was supplied, so a
        # "reported an error" alert can never go out with a blank body.
        error = error.to_s.strip.slice(0, Stablemate::ERROR_MESSAGE_LIMIT).presence ||
                "(no error details reported)"

        # with_lock reloads under SELECT ... FOR UPDATE so the transition reads
        # fresh status: a failure racing a success (or another failure) serialises,
        # and only one opens the incident + emits the down alert.
        @monitor.with_lock do
          @monitor.ping_events.create!(
            received_at:,
            kind: "failure",
            error:,
            source_ip:,
            duration_ms:
          )

          @monitor.last_ping_at = received_at
          @monitor.next_due_at  = next_due_from(received_at)
          # A failure is still contact: measurement starts (WU-10) — otherwise the
          # uptime bar shows no-data through a reported outage, which reads as
          # "not monitored" when it's "down". Never moved afterward.
          @monitor.first_ping_at ||= received_at

          down_notification = apply_transition(received_at, error)
          @monitor.save!
        end

        Notifications::Dispatch.new(down_notification).deliver if down_notification
        @monitor.broadcast_status_update
        @monitor
      end

      private
        # Returns a `down` Notification to dispatch (up/pending -> down only), else nil.
        def apply_transition(received_at, error)
          case @monitor.status
          when "paused", "suspended"
            # Same rule as CheckIn: a stray ping (of either polarity) must not
            # silently resume or alert a deliberately-unmonitored monitor.
            nil
          when "down"
            # Already down: the event is recorded above, but the open incident
            # keeps its original cause/error and nothing re-alerts (§12-B, §5.1).
            nil
          else # pending or up
            @monitor.status = "down"
            incident = open_incident(received_at, error)
            build_notification(incident)
          end
        end

        # Open a fresh incident only when none is currently open — same guard +
        # savepoint pattern as MissedPing#open_incident: the row lock serialises
        # every incident-creating path, the partial unique index is the backstop,
        # and requires_new keeps a RecordNotUnique from poisoning the outer
        # transaction (the status="down" flip still commits).
        def open_incident(now, error)
          return nil if @monitor.incidents.open.exists?

          @monitor.transaction(requires_new: true) do
            @monitor.incidents.create!(started_at: now, cause: "reported_error", error:)
          end
        rescue ActiveRecord::RecordNotUnique
          nil
        end

        def build_notification(incident)
          return nil unless incident

          @monitor.notifications.create!(
            incident:,
            channel: "email",
            event: "down"
          )
        end

        def next_due_from(received_at)
          return nil if @monitor.expected_interval_seconds.blank?

          received_at + @monitor.expected_interval_seconds.seconds
        end
    end
  end
end
