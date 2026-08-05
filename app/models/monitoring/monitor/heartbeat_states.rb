module Monitoring
  class Monitor
    # Status is a plain string column (no state-machine gem); the transitions
    # themselves live in the CheckIn / MissedPing operations and the Pausing /
    # Suspension concerns.
    #
    # `suspended` is a plan-downgrade deactivation, distinct from user-initiated
    # `paused`: not monitored, sends no alerts, and — unlike `paused` — does NOT
    # count toward the cap.
    module HeartbeatStates
      extend ActiveSupport::Concern

      STATUSES = %w[pending up down paused suspended].freeze

      included do
        validates :status, inclusion: { in: STATUSES }

        # Only `up` monitors can transition to `down`: `down` ones are already down
        # (transition-only alerting — one down email per incident).
        scope :detectable, -> { where(status: "up") }

        # next_due_at already encodes the interval, so we only add the grace on top.
        # NULL next_due_at (never computed) is excluded by the comparison.
        scope :overdue, lambda {
          detectable.where(
            "next_due_at + make_interval(secs => grace_period_seconds) < ?",
            Time.current
          )
        }

        # `paused` deliberately still counts (locked decision #8), `suspended`
        # deliberately does not (PRD §3.3).
        scope :counting_toward_cap, -> { where.not(status: "suspended") }

        # next_due_at is derived from (last contact + interval), so an interval edit
        # has to re-derive it or the OLD cadence keeps driving detection: loosening
        # hourly -> daily would still fire a false `down` an hour later. On the model
        # rather than in the edit action so every write path (form, gem sync,
        # console) gets it.
        #
        # before_update, not before_save: on create the interval is not "changing"
        # in any meaningful sense, and a caller that supplies its own next_due_at
        # alongside it must be taken at its word.
        before_update :recompute_next_due_at, if: :expected_interval_seconds_changed?
      end

      def pending?   = status == "pending"
      def up?        = status == "up"
      def down?      = status == "down"
      def paused?    = status == "paused"
      def suspended? = status == "suspended"

      # Eligible for detection and uptime measurement. A `down` monitor is still
      # monitored (it's mid-outage).
      def monitored? = up? || down?

      def ever_pinged?
        last_ping_at.present?
      end

      # Advance the contact timestamps for a ping of either polarity — the job ran
      # (successfully or not), so the next run is expected one interval out.
      # first_ping_at is recorded once, as the floor for uptime measurement: days
      # before it are no-data, never phantom-up. Assigns only — the calling
      # operation saves inside its lock.
      def register_contact(received_at)
        self.last_ping_at  = received_at
        self.next_due_at   = due_after(received_at)
        self.first_ping_at ||= received_at
      end

      def due_with_grace_at
        return nil if next_due_at.blank?

        next_due_at + grace_period_seconds.to_i.seconds
      end

      def overdue_now?
        due = due_with_grace_at
        due.present? && Time.current > due
      end

      # Distinct from bare `up?`: an up monitor can already be past next_due_at but
      # still inside its grace window, so next_due_at is stale — this is false
      # rather than show an already-past time as if it were still upcoming.
      def next_check_upcoming?
        up? && next_due_at.present? && next_due_at.future?
      end

      def grace_period_configured?
        grace_period_seconds.to_i.positive?
      end

      # Bring a non-monitored monitor (paused or suspended) back to live — the
      # single home for this rule, shared by user-resume and plan-reactivate. An
      # already-overdue monitor is routed through flag_missed! rather than a bare
      # status="down", which would leave an incident-less, alert-less outage that
      # detection (status="up" only) never revisits.
      def reactivate_heartbeat!
        unless ever_pinged?
          update!(status: "pending")
          return
        end

        update!(status: "up")
        if overdue_now?
          flag_missed!
        else
          # Belt-and-braces: never leave a stranded open incident on a live `up`
          # monitor. Clearing it here is not a ping recovery, so it emits no alert.
          resolve_open_incident!
        end
      end

      private
        # Re-derive from the last contact we actually had — the same formula
        # register_contact uses, so the two can't drift. A never-pinged monitor has
        # nothing to measure from, so next_due_at stays nil rather than being
        # invented from now.
        def recompute_next_due_at
          self.next_due_at = due_after(last_ping_at) if last_ping_at.present?
        end

        def due_after(contact_at)
          return nil if expected_interval_seconds.blank?

          contact_at + expected_interval_seconds.seconds
        end
    end
  end
end
