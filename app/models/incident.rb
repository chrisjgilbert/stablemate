class Incident < ApplicationRecord
  belongs_to :monitor, class_name: "Monitoring::Monitor", inverse_of: :incidents
  has_many :notifications, dependent: :destroy

  scope :open, -> { where(resolved_at: nil) }

  # An incident is "open" until it is resolved by a recovering ping.
  def open?
    resolved_at.nil?
  end

  # Close the incident now (idempotent: a resolved incident stays put).
  def resolve!(at: Time.current)
    return if resolved_at.present?

    update!(resolved_at: at)
  end
end
