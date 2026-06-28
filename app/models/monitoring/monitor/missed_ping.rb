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

      def call(now: Time.current)
        return @monitor unless @monitor.up?

        incident = nil

        @monitor.transaction do
          @monitor.update!(status: "down")
          incident = open_incident(now)
          @notification = build_notification(incident)
        end

        Notifications::Dispatch.new(@notification).deliver if @notification
        @monitor.broadcast_status_update
        @monitor
      end

      private
        # Open a fresh incident only when none is currently open. A race that
        # slips two callers past this guard is caught by the partial unique index
        # (raising RecordNotUnique), so we never double-alert.
        def open_incident(now)
          return nil if @monitor.incidents.open.exists?

          @monitor.incidents.create!(started_at: now, cause: "missed_ping")
        rescue ActiveRecord::RecordNotUnique
          nil
        end

        def build_notification(incident)
          return nil unless incident

          @monitor.notifications.create!(
            incident:,
            channel: "email",
            event: "down"
          )
        end
    end
  end
end
