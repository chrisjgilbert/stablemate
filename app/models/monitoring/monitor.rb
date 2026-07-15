module Monitoring
  # The heartbeat/cron monitor — the centre of gravity of the domain.
  #
  # DEVIATION (CLAUDE.md "Deviate, but say so"): architecture.md names this class
  # `Monitor` at the top level. That is impossible on Rails 8 + Ruby 3.3: Active
  # Record and concurrent-ruby both rely on the stdlib `::Monitor` class at
  # runtime (e.g. `@load_schema_monitor = Monitor.new` in ActiveRecord, and a
  # hard-coded `::Monitor.new` in concurrent-ruby), so a top-level `Monitor`
  # Active Record model collides fatally. We therefore namespace the model under
  # `Monitoring` (table stays `monitors`, association stays `:monitors`, the
  # instance API — `monitor.check_in!` — is unchanged). Nested objects keep their
  # normative names under this scope: `Monitoring::Monitor::CheckIn`,
  # `Monitoring::Monitor::PingToken`.
  class Monitor < ApplicationRecord
    self.table_name = "monitors"

    # The class is namespaced under Monitoring (see the deviation note above), but
    # the domain — routes, form helpers, dom_id, I18n — is plain "monitor". Pin
    # the model name so `redirect_to @monitor`, `form_with model:`,
    # `monitor_path`, and `dom_id(monitor)` all resolve to the un-namespaced
    # "monitor" rather than "monitoring_monitor".
    def self.model_name
      ActiveModel::Name.new(self, nil, "Monitor")
    end

    include PingToken
    include HeartbeatStates
    include Pausing
    include Uptime

    belongs_to :project
    # Ownership flows monitor → project → user (docs/specs/projects.md §4.2).
    # `monitor.user` is delegated so within_monitor_cap, mailers, and broadcasts
    # keep working; allow_nil avoids a NoMethodError on a monitor built before its
    # project is set.
    delegate :user, to: :project, allow_nil: true
    has_many :ping_events, dependent: :destroy, foreign_key: :monitor_id, inverse_of: :monitor
    has_many :incidents, dependent: :destroy, foreign_key: :monitor_id, inverse_of: :monitor
    has_many :notifications, dependent: :destroy, foreign_key: :monitor_id, inverse_of: :monitor
    has_many :uptime_day_stats, dependent: :destroy, foreign_key: :monitor_id, inverse_of: :monitor

    validates :name, presence: true
    validates :status, presence: true
    validates :expected_interval_seconds, numericality: { greater_than: 0 }
    validates :grace_period_seconds, numericality: { greater_than_or_equal_to: 0 }
    validate :within_monitor_cap, on: :create

    # Live status: each monitor row/badge lives in its own Turbo Stream channel so
    # a ping or a detection sweep can replace just that fragment over Solid Cable,
    # with no client polling. (Broadcasts are wired explicitly from the
    # operations so they fire exactly on a real state change, not every save.)
    def broadcast_status_update
      %i[row badge].each do |fragment|
        broadcast_replace_later_to(
          self,
          target: ActionView::RecordIdentifier.dom_id(self, fragment),
          partial: "monitors/#{fragment}",
          locals: { monitor: self }
        )
      end
    end

    # The monitor's currently-open incident, if any. The open-incident invariant
    # (the partial unique index on monitor_id WHERE resolved_at IS NULL) guarantees
    # at most one, so callers rely on this single accessor rather than each
    # re-expressing `incidents.open.first`.
    def open_incident
      incidents.open.first
    end

    # Resolve the currently-open incident, if any, WITHOUT emitting a recovery
    # alert — used when a monitor leaves the live (monitored) state via
    # pause/suspend, so it never carries a stranded open incident into a
    # not-measured window (which the rollup would otherwise count as downtime
    # forever). Idempotent. Recovery-by-ping stays in CheckIn (it also alerts).
    def resolve_open_incident!(at: Time.current)
      open_incident&.resolve!(at:)
    end

    # Record a ping: persist a PingEvent, advance the timestamps, transition, and
    # (on recovery) resolve the incident + enqueue a `recovered` alert. The facade
    # routes by polarity — a failed ping is still a check-in, of bad news — with
    # each outcome keeping its own operation, mirroring the CheckIn / MissedPing
    # split (job-failure-details.md §5).
    def check_in!(received_at: Time.current, kind: "success", error: nil,
                  source_ip: nil, duration_ms: nil)
      if kind == "failure"
        FailureReport.new(self).report_failure!(received_at:, error:, source_ip:, duration_ms:)
      else
        CheckIn.new(self).check_in!(received_at:, source_ip:, duration_ms:)
      end
    end

    # Flag this monitor down because its ping is overdue (called by the detection
    # job for every monitor in the `overdue` scope).
    def flag_missed!
      MissedPing.new(self).flag_missed!
    end

    # Aggregate one day's up/down seconds + ping count into a UptimeDayStat
    # (idempotent upsert). Called by RollupUptimeJob for each day not yet rolled.
    def roll_up_uptime(day)
      UptimeRollup.new(self).roll_up_uptime(day)
    end

    # Plan-downgrade (de)activation (hosted tier only — issue #19). A suspended
    # monitor is retained but not monitored/alerted and excluded from the cap.
    def suspend!    = Suspension.new(self).suspend!
    def reactivate! = Suspension.new(self).reactivate!

    # Move a manual monitor into another of the user's projects (projects.md §6).
    # Returns a Transfer::Result — a gem monitor or a target collision is a clean
    # `ok? == false`, not an exception.
    def transfer_to(project)
      Transfer.new(self).transfer_to(project)
    end

    private
      # A user may own at most MAX_MONITORS_PER_USER monitors — paused ones still
      # occupy a slot (locked decision #8). Only blocks creation; editing an
      # existing monitor at the cap is always allowed.
      def within_monitor_cap
        return if user.blank?
        return unless user.at_monitor_cap?

        errors.add(:base, "You've reached the limit of #{user.monitor_limit} monitors.")
      end
  end
end
