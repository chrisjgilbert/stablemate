class CreateUptimeDayStats < ActiveRecord::Migration[8.1]
  def change
    create_table :uptime_day_stats do |t|
      t.references :monitor, null: false, foreign_key: true
      t.date :day, null: false
      t.integer :up_seconds, null: false, default: 0
      t.integer :down_seconds, null: false, default: 0
      t.integer :ping_count, null: false, default: 0

      t.timestamps
    end

    # One stat row per monitor per day — the idempotent upsert key. Re-rolling a
    # day overwrites this row rather than inserting a duplicate.
    add_index :uptime_day_stats, %i[monitor_id day], unique: true
  end
end
