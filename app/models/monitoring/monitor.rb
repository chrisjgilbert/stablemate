module Monitoring
  # DEVIATION (CLAUDE.md "Deviate, but say so"): architecture.md names this class
  # `Monitor` at the top level. That is impossible on Rails 8 + Ruby 3.3: Active
  # Record and concurrent-ruby both rely on the stdlib `::Monitor` class at
  # runtime, so a top-level `Monitor` Active Record model collides fatally. We
  # therefore namespace the model under `Monitoring` (table stays `monitors`,
  # association stays `:monitors`, the instance API is unchanged).
  class Monitor < ApplicationRecord
    self.table_name = "monitors"

    # The class is namespaced under Monitoring (see above), but the domain —
    # routes, form helpers, dom_id, I18n — is plain "monitor".
    def self.model_name
      ActiveModel::Name.new(self, nil, "Monitor")
    end

    include PingToken
    include HeartbeatStates
    include Pausing
    include Uptime

    belongs_to :project
    delegate :user, to: :project, allow_nil: true

    # delete_all, not destroy, for the two high-volume leaf tables: a busy account
    # holds hundreds of thousands of rows, and destroying them row-by-row measured
    # ~0.5ms each — a minute or more inside one open transaction. Both tables are
    # leaves (no dependent associations, no destroy callbacks, nothing observes
    # them), so a single bulk DELETE is equivalent.
    has_many :ping_events, dependent: :delete_all, foreign_key: :monitor_id, inverse_of: :monitor
    has_many :incidents, dependent: :destroy, foreign_key: :monitor_id, inverse_of: :monitor
    has_many :notifications, dependent: :destroy, foreign_key: :monitor_id, inverse_of: :monitor
    has_many :uptime_day_stats, dependent: :delete_all, foreign_key: :monitor_id, inverse_of: :monitor

    # Deleting a monitor can be the act that settles an account locked into the
    # choose-N picker. On the record rather than MonitorsController#destroy so
    # every deletion path gets it. after_destroy_commit because the release
    # rewrites the user row, so it must not run if the deletion rolls back.
    after_destroy_commit :release_owner_downgrade_lock

    validates :name, presence: true
    validates :status, presence: true
    validates :expected_interval_seconds, numericality: { greater_than: 0 }
    validates :grace_period_seconds, numericality: { greater_than_or_equal_to: 0 }
    validate :within_monitor_cap, on: :create

    # Deferred to after commit because the webhook paths reach here inside
    # ProcessedEvent.record_once's transaction, and Solid Queue is a SEPARATE
    # database — a job enqueued pre-commit can be claimed by a worker that renders
    # the monitor as it was before the change, and a rollback leaves an orphan job.
    # With no transaction open this runs inline, unchanged.
    def broadcast_status_update
      ActiveRecord.after_all_transactions_commit do
        %i[row badge].each do |fragment|
          broadcast_replace_later_to(
            self,
            target: ActionView::RecordIdentifier.dom_id(self, fragment),
            partial: "monitors/#{fragment}",
            locals: { monitor: self }
          )
        end
      end
    end

    def from_gem? = source == "gem"
    def manual?   = source == "manual"

    def awaiting_setup? = manual? && !ever_pinged? && !suspended?

    # The open-incident invariant (the partial unique index on monitor_id WHERE
    # resolved_at IS NULL) guarantees at most one.
    def open_incident
      incidents.open.first
    end

    # Resolve the currently-open incident WITHOUT emitting a recovery alert — used
    # when a monitor leaves the live (monitored) state via pause/suspend, so it
    # never carries a stranded open incident into a not-measured window (which the
    # rollup would otherwise count as downtime forever). Idempotent.
    def resolve_open_incident!(at: Time.current)
      open_incident&.resolve!(at:)
    end

    # Returns the `down` Notification to dispatch, or nil when an incident was
    # already open (transition-only alerting: one email in, one out).
    #
    # The calling operation's row lock serialises every incident-creating path, so
    # the exists? guard is decisive; the partial unique index is the last-resort
    # backstop, and requires_new confines a RecordNotUnique to its savepoint so
    # rescuing it does NOT poison the caller's outer transaction.
    def open_incident!(at:, cause:, error: nil)
      return nil if incidents.open.exists?

      incident =
        transaction(requires_new: true) do
          incidents.create!(started_at: at, cause:, error:)
        end
      notifications.create!(incident:, channel: "email", event: "down")
    rescue ActiveRecord::RecordNotUnique
      nil
    end

    def check_in!(received_at: Time.current, kind: "success", error: nil,
                  source_ip: nil, duration_ms: nil)
      # An unknown kind raises rather than falling through to the success arm: a
      # typo'd kind silently recorded as a success would transmute a reported
      # failure into a recovery.
      case kind.to_s
      when "failure"
        FailureReport.new(self).report_failure!(received_at:, error:, source_ip:, duration_ms:)
      when "success"
        CheckIn.new(self).check_in!(received_at:, source_ip:, duration_ms:)
      else
        raise ArgumentError, "unknown check-in kind: #{kind.inspect}"
      end
    end

    def flag_missed!
      MissedPing.new(self).flag_missed!
    end

    def roll_up_uptime(day)
      UptimeRollup.new(self).roll_up_uptime(day)
    end

    # A suspended monitor is retained but not monitored/alerted and excluded from
    # the cap.
    def suspend!    = Suspension.new(self).suspend!
    def reactivate! = Suspension.new(self).reactivate!

    # A retired monitor is the same, for a different reason: its task left the
    # repo's config and `PRUNE=1` pruned it. Only a sync that sees the task again
    # brings it back.
    def retire! = Retirement.new(self).retire!
    def revive!(at: Time.current) = Retirement.new(self).revive!(at:)

    # Returns a Transfer::Result — a gem monitor or a target collision is a clean
    # `ok? == false`, not an exception.
    def transfer_to(project)
      Transfer.new(self).transfer_to(project)
    end

    private
      # Skipped when the owner is going away too: closing an account cascades
      # through here, and the user row is already deleted — and already frozen in
      # memory, so writing to it would raise inside the commit callback and take
      # the closure down with it.
      def release_owner_downgrade_lock
        return if user.nil? || user.destroyed?

        user.release_downgrade_lock_if_within_cap!
      end

      def within_monitor_cap
        return if user.blank?
        return unless user.at_monitor_cap?

        errors.add(:base, "You've reached the limit of #{user.monitor_limit} monitors.")
      end
  end
end
