module Monitoring
  class Monitor
    # Pause/resume: simple state flips driven by the user, reached via
    # monitor.pause! / monitor.resume!. A paused monitor is excluded from
    # detection and alerting (see HeartbeatStates#overdue).
    module Pausing
      extend ActiveSupport::Concern

      # Stop monitoring. Records nothing else — detection simply skips paused
      # monitors. Idempotent.
      def pause!
        update!(status: "paused")
      end

      # Resume monitoring, re-evaluated against the grace window:
      #   - never pinged                -> pending
      #   - within interval + grace     -> up
      #   - already past it (overdue)   -> open an incident and alert, exactly as
      #     the detection sweep would. We route through flag_missed! rather than
      #     flipping the column straight to "down" so the incident invariant and
      #     the down alert always hold; a bare status="down" would leave an
      #     incident-less, alert-less outage that detection (status="up" only)
      #     never revisits.
      def resume!
        unless ever_pinged?
          update!(status: "pending")
          return
        end

        update!(status: "up")
        flag_missed! if overdue_now?
      end

      private
        def overdue_now?
          due = due_with_grace_at
          due.present? && Time.current > due
        end
    end
  end
end
