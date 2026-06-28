class PingEvent < ApplicationRecord
  # Append-only audit rows: the table has created_at and no updated_at, so Rails'
  # default timestamping sets created_at on create and ignores the missing
  # updated_at — no manual plumbing needed.
  belongs_to :monitor, class_name: "Monitoring::Monitor", inverse_of: :ping_events

  # Raw pings older than the retention window are prunable (the rule lives here,
  # on the record; PrunePingEventsJob is iteration only). Relative to the constant
  # so changing PING_RETENTION changes the cutoff without touching the job/tests.
  scope :prunable, -> { where(received_at: ...Stablemate::PING_RETENTION.ago) }

  # Delete prunable pings, one (monitor, day) bucket at a time, in batches.
  #
  # Safety check (spec §3.3): a day's raw pings are only deleted once that day has
  # a UptimeDayStat — pruning never destroys un-rolled data. A prunable day with
  # no rollup is skipped and logged rather than deleted blind. This invariant
  # lives on the record (callable/testable directly); the job just calls it.
  def self.prune!
    prunable_days.each do |monitor_id, day|
      if UptimeDayStat.exists?(monitor_id:, day:)
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
