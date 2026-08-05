module Monitoring
  class Monitor
    # Pause/resume: user-driven state flips, reached via monitor.pause! /
    # monitor.resume!.
    module Pausing
      extend ActiveSupport::Concern

      # Resolving any open incident first means a paused monitor never carries a
      # stranded outage into its not-measured window. Idempotent.
      #
      # with_lock (not a bare transaction) so the incident is read under
      # SELECT ... FOR UPDATE. Reading it unlocked let a detection sweep open an
      # incident — and send the down email the user was silencing — between the read
      # and the flip, leaving the monitor `paused` with an open incident that the
      # rollup counts as downtime forever.
      def pause!
        with_lock do
          resolve_open_incident!
          update!(status: "paused")
        end
      end

      def resume!
        reactivate_heartbeat!
      end
    end
  end
end
