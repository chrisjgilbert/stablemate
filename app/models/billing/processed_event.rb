module Billing
  # Idempotency ledger for Stripe webhooks (issue #19). The unique index on
  # event_id makes #record_once the single arbiter of "have we handled this
  # delivery before?", so a Stripe replay produces exactly one effect.
  class ProcessedEvent < ApplicationRecord
    self.table_name = "billing_processed_events"

    # Claim a Stripe event id, yielding the block only the first time. A duplicate
    # delivery loses the insert race (or finds the row) and the block is skipped.
    # Returns true if this call did the processing, false if it was a duplicate.
    #
    # The claim and the block run in one transaction: if the block raises, the
    # ledger row rolls back too, so the event is NOT marked processed and Stripe's
    # retry can reprocess it (no silently-lost webhook). The unique index still
    # makes concurrent duplicate deliveries safe — the loser hits RecordNotUnique.
    def self.record_once(event_id, event_type:)
      transaction do
        create!(event_id: event_id, event_type: event_type)
        yield
      end
      true
    rescue ActiveRecord::RecordNotUnique
      false
    end
  end
end
