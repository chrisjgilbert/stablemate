module Monitoring
  class Monitor
    # Flag a monitor as down because its ping is overdue. Reached via
    # monitor.flag_missed!, called by DetectMissedPingsJob for every monitor in the
    # `overdue` scope.
    class MissedPing
      def initialize(monitor)
        @monitor = monitor
      end

      def flag_missed!(now: Time.current)
        # Re-validate under a row lock: the detection sweep holds a record loaded by
        # the `overdue` query, which a legitimate late ping may have moved on since.
        # Without the re-check a boundary ping would be overwritten with a false
        # `down` (and a spurious alert).
        @monitor.with_lock do
          return @monitor unless @monitor.up? && @monitor.overdue_now?

          @monitor.update!(status: "down")
          @notification = @monitor.open_incident!(at: now, cause: "missed_ping")
        end

        Notifications::Dispatch.new(@notification).deliver if @notification
        @monitor.broadcast_status_update
        @monitor
      end
    end
  end
end
