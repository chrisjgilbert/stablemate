module Monitoring
  class Monitor
    # Operation object: flag a monitor as down because its ping is overdue.
    # Reached via monitor.flag_missed!, called by DetectMissedPingsJob for every
    # monitor in the `overdue` scope. Pure DB work — no outbound HTTP here; the
    # alert email is enqueued via deliver_later inside Notifications::Dispatch.
    #
    #   1. Transition up -> down.
    #   2. Open an Incident (guarded by the open-incident invariant — the partial
    #      unique index is the DB backstop).
    #   3. Create a `down` Notification and hand it to Notifications::Dispatch.
    #   4. Broadcast a Turbo Stream badge/row update over Solid Cable.
    #
    # Transition-only alerting (locked decision #2): because we only open an
    # incident when none is open, a continuing outage produces exactly one down
    # email. A non-`up` monitor is a no-op (defensive; the scope already filters).
    class MissedPing
      def initialize(monitor)
        @monitor = monitor
      end

      def flag_missed!(now: Time.current)
        # Re-validate under a row lock: the detection sweep holds a record loaded by
        # the `overdue` query, which a legitimate late ping may have moved on since.
        # with_lock reloads via SELECT ... FOR UPDATE, so we re-check the monitor is
        # STILL up AND still overdue against fresh state — otherwise a boundary ping
        # would be overwritten with a false `down` (and a spurious alert).
        @monitor.with_lock do
          return @monitor unless @monitor.up? && @monitor.overdue_now?

          @monitor.update!(status: "down")
          # Shared down-transition bookkeeping (Monitor#open_incident!): opens the
          # incident + `down` Notification only when none is open, so a continuing
          # outage still produces exactly one down email.
          @notification = @monitor.open_incident!(at: now, cause: "missed_ping")
        end

        Notifications::Dispatch.new(@notification).deliver if @notification
        @monitor.broadcast_status_update
        @monitor
      end
    end
  end
end
