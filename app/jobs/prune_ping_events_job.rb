# Recurring daily pruning (see config/recurring.yml).
class PrunePingEventsJob < ApplicationJob
  queue_as :default

  def perform
    PingEvent.prune!
  end
end
