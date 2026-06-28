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

    include PingToken

    belongs_to :user
    has_many :ping_events, dependent: :destroy, foreign_key: :monitor_id, inverse_of: :monitor

    validates :name, presence: true
    validates :status, presence: true

    # Record a ping: persist a PingEvent, advance the timestamps, and (first
    # form) transition pending -> up. Delegates to the CheckIn operation object.
    def check_in!(received_at: Time.current, source_ip: nil, duration_ms: nil)
      CheckIn.new(self).call(received_at:, source_ip:, duration_ms:)
    end
  end
end
