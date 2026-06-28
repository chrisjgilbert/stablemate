class CreateIncidents < ActiveRecord::Migration[8.1]
  def change
    create_table :incidents do |t|
      t.references :monitor, null: false, foreign_key: true
      t.datetime :started_at, null: false
      t.datetime :resolved_at
      t.string :cause, null: false, default: "missed_ping"

      t.timestamps
    end

    # At most one *open* (unresolved) incident per monitor — the DB backstop for
    # the transition-only alerting invariant (one down email per incident).
    add_index :incidents, :monitor_id,
              unique: true,
              where: "resolved_at IS NULL",
              name: "index_incidents_on_monitor_id_open"
  end
end
