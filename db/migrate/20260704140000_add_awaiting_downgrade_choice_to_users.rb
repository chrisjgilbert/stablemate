class AddAwaitingDowngradeChoiceToUsers < ActiveRecord::Migration[8.1]
  # WU-6: an involuntary drop to Free while over the cap locks the account into a
  # "choose which N to keep" decision. Represent that state explicitly rather than
  # deriving it from the suspended-count (which can't tell an involuntary lock from
  # a user-chosen suspension). Default false; only the webhook sync sets it.
  def change
    add_column :users, :awaiting_downgrade_choice, :boolean, null: false, default: false
  end
end
