# The check-in credential (sm_ping_…), deliberately a SEPARATE table from
# api_keys rather than a `type` column on it (v1-scope §4): authentication looks a
# token up across a whole table, so one table would let a ping key authenticate
# the management API unless every lookup remembered to filter — and forgetting is
# silent and permissive. Two tables make the mistake impossible.
#
# A project may hold MORE than one live key so rotation can overlap: issue the
# second, deploy it, watch the first key's last_used_at stop moving, revoke it.
class CreatePingKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :ping_keys do |t|
      t.references :project, null: false, foreign_key: true
      t.string :name, null: false
      # SHA-256 hex digest of the raw key — the raw key itself is never persisted.
      t.string :token_digest, null: false
      # Last 4 chars of the raw key, for the masked UI display (sm_ping_••••a14c).
      t.string :token_last4, null: false
      t.datetime :last_used_at

      t.timestamps
    end

    add_index :ping_keys, :token_digest, unique: true
  end
end
