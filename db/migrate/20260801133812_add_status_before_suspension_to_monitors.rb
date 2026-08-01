# A plan downgrade suspends paused monitors too (they occupy a cap slot, locked
# decision #8), and reactivation had no way to tell them apart from live ones —
# so a re-upgrade un-paused a monitor the user had deliberately silenced. Remember
# what we suspended FROM, so reactivation can put it back. Nullable and cleared on
# reactivation: it is per-suspension memory, not history.
class AddStatusBeforeSuspensionToMonitors < ActiveRecord::Migration[8.1]
  def change
    add_column :monitors, :status_before_suspension, :string
  end
end
