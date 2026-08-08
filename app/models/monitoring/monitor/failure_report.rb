module Monitoring
  class Monitor
    # Record a reported-failure ping — "I ran, but I failed". Reached via
    # monitor.check_in!(kind: "failure"). There is no grace: an explicit failure is
    # a positive statement, not uncertainty of absence.
    class FailureReport
      def initialize(monitor)
        @monitor = monitor
      end

      def report_failure!(received_at: Time.current, error: nil, source_ip: nil, duration_ms: nil)
        down_notification = nil
        # The model layer owns BOTH text bounds so every caller shares them:
        # truncation, and a stub when no error text was supplied, so a "reported an
        # error" alert can never go out with a blank body.
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

          # A failure is still contact — timestamps advance exactly as a success:
          # otherwise the uptime bar shows no-data through a reported outage,
          # which reads as "not monitored" when it's "down".
          @monitor.register_contact(received_at)

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
          when *Monitor::NOT_MONITORED_STATUSES
            # Same rule as CheckIn, and this is a SECOND copy of it rather than a
            # shared one: a `retired` monitor missing from here alone would let a
            # still-running cron reporting status=1 flip it to down, open an
            # incident, email a false outage and re-occupy a cap slot.
            nil
          when "down"
            # The event is recorded above, but the open incident keeps its original
            # cause/error and nothing re-alerts (one email in, one email out).
            nil
          else # pending or up
            @monitor.status = "down"
            @monitor.open_incident!(at: received_at, cause: "reported_error", error:)
          end
        end
    end
  end
end
