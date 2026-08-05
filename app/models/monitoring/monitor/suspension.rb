module Monitoring
  class Monitor
    # Plan-downgrade (de)activation — reached via monitor.suspend! / monitor.reactivate!.
    #
    # Retention (PRD §8 Q10): suspended monitors are kept forever — there is NO
    # auto-purge job. A purge/retention policy is deliberately deferred.
    class Suspension
      def initialize(monitor)
        @monitor = monitor
      end

      # Idempotent — an already-suspended monitor keeps the status it was suspended
      # FROM, so a second call can't overwrite the memory with "suspended" and lose
      # the user's pause.
      #
      # with_lock (not a bare transaction) so the incident is read under
      # SELECT ... FOR UPDATE. Reading it unlocked let a detection sweep open an
      # incident — and email a monitor the downgrade had just stopped monitoring —
      # between the read and the flip, leaving `suspended` with an open incident the
      # rollup counts as downtime forever.
      def suspend!
        @monitor.with_lock do
          next if @monitor.suspended?

          suspending_from = @monitor.status
          @monitor.resolve_open_incident!
          @monitor.update!(status: "suspended", status_before_suspension: suspending_from)
        end
      end

      # A monitor the user had already PAUSED goes straight back to `paused`, never
      # through the heartbeat re-evaluation: callers suspend paused monitors too
      # (they occupy a cap slot — locked #8), and re-evaluating one would un-pause it
      # and, if the silenced window had run long, open an incident and email an
      # outage for a monitor nobody was watching.
      #
      # Every other pre-suspension status re-evaluates the grace window: restoring a
      # stale `up`/`down` verbatim would either hide a real outage or assert one that
      # may have ended. Monitors suspended before status_before_suspension existed
      # read nil here and take that branch. Deliberately not backfilled: nothing
      # records whether they had been paused, and guessing "paused" would silently
      # stop monitoring live jobs.
      def reactivate!
        return unless @monitor.suspended?

        if @monitor.status_before_suspension == "paused"
          @monitor.update!(status: "paused", status_before_suspension: nil)
        else
          # Cleared first so the memory can never outlive its suspension — the
          # next downgrade must remember afresh.
          @monitor.update!(status_before_suspension: nil)
          @monitor.reactivate_heartbeat!
        end
      end
    end
  end
end
