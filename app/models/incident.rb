class Incident < ApplicationRecord
  belongs_to :monitor, class_name: "Monitoring::Monitor", inverse_of: :incidents
  has_many :notifications, dependent: :destroy

  # What took the monitor down: a ping that never arrived, or a ping that
  # explicitly reported an error (job-failure-details.md). A reported_error
  # incident also carries the `error` text from the failure ping that opened it.
  CAUSES = %w[missed_ping reported_error].freeze

  validates :cause, inclusion: { in: CAUSES }

  scope :open, -> { where(resolved_at: nil) }

  # An incident is "open" until it is resolved by a recovering ping.
  def open?
    resolved_at.nil?
  end

  # The job ran and told us it failed, vs the silent missed_ping. ONE predicate
  # next to CAUSES so the mailer, the banner, and the events feed can't drift
  # (or typo) the cause string independently.
  def reported_error?
    cause == "reported_error"
  end

  # Close the incident now (idempotent: a resolved incident stays put).
  def resolve!(at: Time.current)
    return if resolved_at.present?

    update!(resolved_at: at)
  end
end
