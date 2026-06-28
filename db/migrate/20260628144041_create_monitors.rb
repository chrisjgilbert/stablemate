class CreateMonitors < ActiveRecord::Migration[8.1]
  def change
    create_table :monitors do |t|
      t.references :user, null: false, foreign_key: true
      t.string :monitor_type, null: false, default: "heartbeat"
      t.string :name, null: false
      t.string :ping_token, null: false
      t.integer :expected_interval_seconds
      t.integer :grace_period_seconds
      t.string :status, null: false, default: "pending"
      t.datetime :last_ping_at
      t.datetime :next_due_at
      t.string :registration_key
      # "manual" for user-created monitors, "gem" for ones synced from the gem.
      t.string :source, null: false, default: "manual"

      t.timestamps
    end

    # The ping token is the credential for the public ping endpoint — must be unique.
    add_index :monitors, :ping_token, unique: true

    # A gem-synced monitor is identified by (user, registration_key); only one
    # per key per user, but manual monitors (NULL key) are unconstrained.
    add_index :monitors, [ :user_id, :registration_key ],
              unique: true,
              where: "registration_key IS NOT NULL",
              name: "index_monitors_on_user_and_registration_key"

    # Detection sweep reads overdue monitors ordered by when they came due.
    add_index :monitors, :next_due_at
    add_index :monitors, [ :status, :next_due_at ]
  end
end
