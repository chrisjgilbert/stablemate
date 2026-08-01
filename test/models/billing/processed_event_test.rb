require "test_helper"

# Billing::ProcessedEvent — the Stripe webhook idempotency ledger (issue #19).
# The unique index on event_id is the arbiter of "have we handled this delivery
# before?"; #record_once turns it into a claim-then-process.
class Billing::ProcessedEventTest < ActiveSupport::TestCase
  test "the first delivery is claimed and processed" do
    ran = false

    assert_difference -> { Billing::ProcessedEvent.count }, 1 do
      assert Billing::ProcessedEvent.record_once("evt_first", event_type: "invoice.paid") { ran = true }
    end

    assert ran
  end

  # A Stripe replay (or a concurrent duplicate delivery losing the insert race)
  # must be a complete no-op — the block never runs, so no double effect.
  test "a repeat delivery is skipped without running the block" do
    Billing::ProcessedEvent.record_once("evt_repeat", event_type: "invoice.paid") { }
    ran = false

    assert_no_difference -> { Billing::ProcessedEvent.count } do
      refute Billing::ProcessedEvent.record_once("evt_repeat", event_type: "invoice.paid") { ran = true }
    end

    refute ran
  end

  # M6 — a unique violation raised by the PROCESSING is not a duplicate delivery.
  # Swallowed, it looked like one: the ledger row rolled back, we returned false,
  # and the controller acked 200 with nothing applied — Stripe never retries, so
  # the event is silently lost (the "customer paid but stayed Free" shape).
  test "a unique violation from inside the block propagates instead of reading as a duplicate" do
    Billing::ProcessedEvent.create!(event_id: "evt_taken", event_type: "invoice.paid")

    assert_raises ActiveRecord::RecordNotUnique do
      Billing::ProcessedEvent.record_once("evt_new", event_type: "invoice.paid") do
        Billing::ProcessedEvent.create!(event_id: "evt_taken", event_type: "invoice.paid")
      end
    end

    # And the claim rolled back with it, so Stripe's retry can reprocess.
    assert_equal 0, Billing::ProcessedEvent.where(event_id: "evt_new").count
  end

  # The claim and the block share one transaction: a failure in the block must
  # un-claim the event so the delivery is retryable.
  test "a failure in the block rolls the claim back" do
    assert_no_difference -> { Billing::ProcessedEvent.count } do
      assert_raises RuntimeError do
        Billing::ProcessedEvent.record_once("evt_boom", event_type: "invoice.paid") { raise "boom" }
      end
    end
  end
end
