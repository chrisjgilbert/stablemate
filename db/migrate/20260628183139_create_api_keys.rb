class CreateApiKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :api_keys do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      # SHA-256 hex digest of the raw key — the raw key itself is never persisted.
      t.string :token_digest, null: false
      # Last 4 chars of the raw key, for the masked UI display (sm_live_••••a14c).
      t.string :token_last4, null: false
      t.datetime :last_used_at

      t.timestamps
    end

    add_index :api_keys, :token_digest, unique: true
  end
end
