class CreateBillingProcessedEvents < ActiveRecord::Migration[8.1]
  # Idempotency ledger for Stripe webhooks (issue #19). Stripe may deliver the
  # same event id more than once; we record each processed id under a unique index
  # so a replay is a no-op. Hosted-tier only — empty on a self-host instance.
  def change
    create_table :billing_processed_events do |t|
      t.string :event_id, null: false
      t.string :event_type
      t.datetime :created_at, null: false
    end
    add_index :billing_processed_events, :event_id, unique: true
  end
end
