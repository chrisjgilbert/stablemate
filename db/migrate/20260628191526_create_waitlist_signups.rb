class CreateWaitlistSignups < ActiveRecord::Migration[8.1]
  def change
    create_table :waitlist_signups do |t|
      t.string :email_address, null: false

      # A waitlist entry is write-once — captured at the cap, never edited. The
      # reconciled data model (README §4) specifies created_at only, no updated_at.
      t.datetime :created_at, null: false
    end

    add_index :waitlist_signups, :email_address, unique: true
  end
end
