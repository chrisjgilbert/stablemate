module Monitoring
  class Monitor
    # Status predicates and the detection scopes. Status is a plain string column
    # (no state-machine gem): pending / up / down / paused. The transitions
    # themselves live in the CheckIn / MissedPing operations and the Pausing
    # concern; this concern is just the vocabulary for reading state.
    module HeartbeatStates
      extend ActiveSupport::Concern

      STATUSES = %w[pending up down paused].freeze

      included do
        validates :status, inclusion: { in: STATUSES }

        # Monitors detection may transition to `down`: only `up` ones. pending
        # (never pinged) and paused ("don't monitor") are excluded by definition,
        # and `down` ones are already down (transition-only alerting — one down
        # email per incident).
        scope :detectable, -> { where(status: "up") }

        # The detection query: an `up` monitor whose grace window has fully
        # elapsed (now is strictly past next_due_at + grace). next_due_at already
        # encodes the interval, so we only add the grace on top. NULL next_due_at
        # (never computed) is excluded by the comparison.
        scope :overdue, lambda {
          detectable.where(
            "next_due_at + make_interval(secs => grace_period_seconds) < ?",
            Time.current
          )
        }
      end

      def pending? = status == "pending"
      def up?      = status == "up"
      def down?    = status == "down"
      def paused?  = status == "paused"

      # Has this monitor ever recorded a ping? Drives resume() and pending state.
      def ever_pinged?
        last_ping_at.present?
      end

      # The moment this monitor is considered overdue (next_due_at + grace),
      # surfaced to the UI ("expected by ...").
      def due_with_grace_at
        return nil if next_due_at.blank?

        next_due_at + grace_period_seconds.to_i.seconds
      end
    end
  end
end
