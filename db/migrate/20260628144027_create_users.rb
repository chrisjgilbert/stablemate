class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :email_address, null: false
      t.string :password_digest, null: false
      t.datetime :verified_at
      t.string :plan, null: false, default: "free"

      t.timestamps
    end

    # Case-insensitive uniqueness without citext: index the lowered address.
    add_index :users, "lower(email_address)", unique: true, name: "index_users_on_lower_email_address"
  end
end
