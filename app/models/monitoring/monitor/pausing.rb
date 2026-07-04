module Monitoring
  class Monitor
    # Pause/resume: simple state flips driven by the user, reached via
    # monitor.pause! / monitor.resume!. A paused monitor is excluded from
    # detection and alerting (see HeartbeatStates#overdue).
    module Pausing
      extend ActiveSupport::Concern

      # Stop monitoring. Resolving any open incident first means a paused monitor
      # never carries a stranded outage into its not-measured window (WU-2). Both
      # writes are one transaction so the monitor never sits paused-with-open-incident.
      # Idempotent.
      def pause!
        transaction do
          resolve_open_incident!
          update!(status: "paused")
        end
      end

      # Resume monitoring, re-evaluated against the grace window (shared rule —
      # see HeartbeatStates#reactivate_heartbeat!).
      def resume!
        reactivate_heartbeat!
      end
    end
  end
end
