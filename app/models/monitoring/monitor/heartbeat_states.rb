module Monitoring
  class Monitor
    # Status predicates and the detection scopes. Status is a plain string column
    # (no state-machine gem): pending / up / down / paused / suspended. The
    # transitions themselves live in the CheckIn / MissedPing operations and the
    # Pausing / Suspension concerns; this concern is just the vocabulary for
    # reading state.
    #
    # `suspended` is hosted-tier only (issue #19): a plan-downgrade deactivation,
    # distinct from user-initiated `paused`. A suspended monitor is not monitored,
    # sends no alerts, and — unlike `paused` — does NOT count toward the cap.
    module HeartbeatStates
      extend ActiveSupport::Concern

      STATUSES = %w[pending up down paused suspended].freeze

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

        # Monitors that occupy a cap slot. Everything except `suspended` counts —
        # `paused` deliberately still counts (locked decision #8), `suspended`
        # (plan-downgrade) deliberately does not (PRD §3.3). Backs
        # User#at_monitor_cap? / #remaining_monitor_slots.
        scope :counting_toward_cap, -> { where.not(status: "suspended") }
      end

      def pending?   = status == "pending"
      def up?        = status == "up"
      def down?      = status == "down"
      def paused?    = status == "paused"
      def suspended? = status == "suspended"

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

      def overdue_now?
        due = due_with_grace_at
        due.present? && Time.current > due
      end

      # Bring a non-monitored monitor (paused or suspended) back to live, choosing
      # the correct status by re-evaluating the grace window — the single home for
      # this rule, shared by user-resume (Pausing) and plan-reactivate (Suspension):
      #   - never pinged             -> pending
      #   - within interval + grace  -> up
      #   - already overdue          -> up, then flag_missed! so the incident +
      #     down alert fire exactly as a detection sweep would. We route through
      #     flag_missed! rather than a bare status="down", which would leave an
      #     incident-less, alert-less outage that detection (status="up" only)
      #     never revisits.
      def reactivate_heartbeat!
        unless ever_pinged?
          update!(status: "pending")
          return
        end

        update!(status: "up")
        flag_missed! if overdue_now?
      end
    end
  end
end
