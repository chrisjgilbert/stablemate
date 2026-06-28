class Notification < ApplicationRecord
  # Audit log of every alert dispatched for a monitor. Channel-agnostic so V2 can
  # add webhook rows without a schema change.
  belongs_to :monitor, class_name: "Monitoring::Monitor", inverse_of: :notifications
  belongs_to :incident, optional: true

  EVENTS = %w[down recovered].freeze

  validates :event, inclusion: { in: EVENTS }
  validates :channel, presence: true
end
