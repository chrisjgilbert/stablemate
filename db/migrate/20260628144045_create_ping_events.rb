class CreatePingEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :ping_events do |t|
      t.references :monitor, null: false, foreign_key: true
      t.datetime :received_at, null: false
      t.string :kind, null: false, default: "success"
      t.string :source_ip
      t.integer :duration_ms

      # Append-only audit rows: created_at only, no updated_at (README §4).
      t.datetime :created_at, null: false
    end
  end
end
