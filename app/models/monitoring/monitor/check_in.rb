module Monitoring
  class Monitor
    # Operation object: record a single ping for a monitor.
    #
    # Reached via `monitor.check_in!(...)`. First form (Phase 0):
    #   1. create a success PingEvent,
    #   2. advance last_ping_at / next_due_at,
    #   3. transition pending -> up (other transitions arrive in Phase 1).
    class CheckIn
      def initialize(monitor)
        @monitor = monitor
      end

      def call(received_at: Time.current, source_ip: nil, duration_ms: nil)
        @monitor.transaction do
          @monitor.ping_events.create!(
            received_at:,
            kind: "success",
            source_ip:,
            duration_ms:
          )

          @monitor.last_ping_at = received_at
          @monitor.next_due_at  = next_due_from(received_at)
          @monitor.status = "up" if @monitor.status == "pending"
          @monitor.save!
        end

        @monitor
      end

      private
        def next_due_from(received_at)
          return nil if @monitor.expected_interval_seconds.blank?

          received_at + @monitor.expected_interval_seconds.seconds
        end
    end
  end
end
