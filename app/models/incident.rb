class Incident < ApplicationRecord
  belongs_to :monitor, class_name: "Monitoring::Monitor", inverse_of: :incidents
  has_many :notifications, dependent: :destroy

  CAUSES = %w[missed_ping reported_error].freeze

  validates :cause, inclusion: { in: CAUSES }

  scope :open, -> { where(resolved_at: nil) }

  def open?
    resolved_at.nil?
  end

  # ONE predicate next to CAUSES so the mailer, the banner, and the events feed
  # can't drift (or typo) the cause string independently.
  def reported_error?
    cause == "reported_error"
  end

  # Idempotent: a resolved incident stays put.
  def resolve!(at: Time.current)
    return if resolved_at.present?

    update!(resolved_at: at)
  end
end
