class CreateNotifications < ActiveRecord::Migration[8.1]
  def change
    create_table :notifications do |t|
      t.references :monitor, null: false, foreign_key: true
      t.references :incident, null: true, foreign_key: true
      t.string :channel, null: false, default: "email"
      t.string :event, null: false
      t.datetime :delivered_at

      # Audit log: created_at is enough, but timestamps keeps it conventional.
      t.timestamps
    end
  end
end
