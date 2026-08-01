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
    # makes concurrent duplicate deliveries safe — the loser's insert fails.
    def self.record_once(event_id, event_type:)
      claimed = false

      transaction do
        claimed = claim(event_id, event_type)
        yield if claimed
      end

      claimed
    end

    # Insert the ledger row, false if this event id is already claimed. Its own
    # savepoint for two reasons: a losing race must not poison the surrounding
    # transaction, and the RecordNotUnique rescue must not reach the caller's block
    # (M6). Rescuing the whole block made a unique violation raised by the
    # *processing* look like a duplicate delivery — we'd ack 200 to Stripe with
    # nothing applied and no retry, silently losing the event.
    def self.claim(event_id, event_type)
      transaction(requires_new: true) { create!(event_id: event_id, event_type: event_type) }
      true
    rescue ActiveRecord::RecordNotUnique
      false
    end
    private_class_method :claim
  end
end
