module Monitoring
  class Monitor
    # Pause/resume: simple state flips driven by the user, reached via
    # monitor.pause! / monitor.resume!. A paused monitor is excluded from
    # detection and alerting (see HeartbeatStates#overdue).
    module Pausing
      extend ActiveSupport::Concern

      # Stop monitoring. Resolving any open incident first means a paused monitor
      # never carries a stranded outage into its not-measured window (WU-2).
      # Idempotent.
      #
      # with_lock (not a bare transaction) so the incident is read under
      # SELECT ... FOR UPDATE, mirroring every ping-path operation. Reading it
      # unlocked let a detection sweep open an incident — and send the down email
      # the user was silencing — between the read and the flip, leaving the
      # monitor `paused` with an open incident that the rollup counts as downtime
      # forever. Under the lock, a racing sweep either commits first (we reload
      # and resolve its incident) or waits and then finds a non-`up` monitor.
      def pause!
        with_lock do
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
