class PingEvent < ApplicationRecord
  # Append-only audit rows: the table has created_at and no updated_at.
  belongs_to :monitor, class_name: "Monitoring::Monitor", inverse_of: :ping_events

  KINDS = %w[success failure].freeze

  validates :kind, inclusion: { in: KINDS }

  scope :prunable, -> { where(received_at: ...Stablemate::PING_RETENTION.ago) }

  # Delete prunable pings, one (monitor, day) bucket at a time, in batches.
  #
  # Safety check (spec §3.3): a day's raw pings are only deleted once that day has
  # a UptimeDayStat — pruning never destroys un-rolled data.
  #
  # …with one exception, or the check deadlocks against the rollup: the backfill is
  # clamped at Monitor.uptime_backfill_horizon, so a day older than that can never
  # gain a stat row however often the rollup runs. Waiting for one there protects
  # nothing and strands those pings for ever, so a pre-horizon day is pruned on its
  # own.
  def self.prune!
    horizon = Monitoring::Monitor.uptime_backfill_horizon

    prunable_days.each do |monitor_id, day|
      if day < horizon || UptimeDayStat.exists?(monitor_id:, day:)
        prunable.where(monitor_id:).where("received_at::date = ?", day).in_batches.delete_all
      else
        Rails.logger.warn(
          "PingEvent.prune!: skipping un-rolled day #{day} for monitor #{monitor_id} " \
          "(no UptimeDayStat) — leaving raw pings intact."
        )
      end
    end
  end

  # The distinct (monitor_id, UTC day) buckets among prunable pings — a small
  # result set even when the underlying rows are many.
  def self.prunable_days
    prunable
      .group(:monitor_id, Arel.sql("received_at::date"))
      .pluck(:monitor_id, Arel.sql("received_at::date"))
  end
end
