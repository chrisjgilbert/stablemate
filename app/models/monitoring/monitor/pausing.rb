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

      # Resume monitoring, re-evaluated against the grace window (shared rule —
      # see HeartbeatStates#reactivate_heartbeat!).
      def resume!
        reactivate_heartbeat!
      end
    end
  end
end
