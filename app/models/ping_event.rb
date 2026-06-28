class PingEvent < ApplicationRecord
  # Append-only audit rows: the table has created_at and no updated_at, so Rails'
  # default timestamping sets created_at on create and ignores the missing
  # updated_at — no manual plumbing needed.
  belongs_to :monitor, class_name: "Monitoring::Monitor", inverse_of: :ping_events
end
