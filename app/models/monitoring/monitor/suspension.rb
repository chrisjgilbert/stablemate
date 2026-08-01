module Monitoring
  class Monitor
    # Plan-downgrade (de)activation — reached via monitor.suspend! / monitor.reactivate!.
    # Hosted-tier only (issue #19): a `suspended` monitor is retained but not
    # monitored, sends no alerts, and does NOT count toward the cap (PRD §3.3),
    # distinct from user-initiated `paused`. Suspending records nothing else —
    # detection already skips non-`up` monitors. Reactivation re-evaluates the
    # heartbeat via the shared HeartbeatStates#reactivate_heartbeat! rule (the same
    # path user-resume uses), so an overdue monitor opens an incident and alerts
    # rather than silently flipping to a stale `up`.
    #
    # Retention (PRD §8 Q10): suspended monitors are kept forever — there is NO
    # auto-purge job. A purge/retention policy is deliberately deferred; we never
    # delete a suspended monitor here.
    class Suspension
      def initialize(monitor)
        @monitor = monitor
      end

      # Deactivate for a plan downgrade. Idempotent.
      #
      # with_lock (not a bare transaction) so the incident is read under
      # SELECT ... FOR UPDATE, mirroring every ping-path operation and Pausing.
      # Reading it unlocked let a detection sweep open an incident — and email a
      # monitor the downgrade had just stopped monitoring — between the read and
      # the flip, leaving `suspended` with an open incident the rollup counts as
      # downtime forever.
      def suspend!
        @monitor.with_lock do
          @monitor.resolve_open_incident!
          @monitor.update!(status: "suspended")
        end
      end

      # Re-activate on re-upgrade. No-op unless actually suspended, so a stray call
      # can't disturb a live monitor.
      def reactivate!
        return unless @monitor.suspended?

        @monitor.reactivate_heartbeat!
      end
    end
  end
end
