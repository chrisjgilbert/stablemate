# Recurring daily pruning (see config/recurring.yml). Orchestration only: the
# prune rule and the "never delete un-rolled data" safety invariant live on
# PingEvent (PingEvent.prune!); this job just delegates. (Phase 2 §3.3)
class PrunePingEventsJob < ApplicationJob
  queue_as :default

  def perform
    PingEvent.prune!
  end
end
