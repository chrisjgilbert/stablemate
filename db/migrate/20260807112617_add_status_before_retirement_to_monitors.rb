# `retired` is the prune state (v1-scope §6.1): a monitor whose task has left the
# config is retired, not deleted — history kept, no cap slot, revived by the sync
# when the task comes back. Retiring a monitor the user had PAUSED must not
# destroy the pause, so retirement remembers what it retired FROM, exactly as
# status_before_suspension does for a plan downgrade. Nullable and cleared on
# revive: per-retirement memory, not history.
class AddStatusBeforeRetirementToMonitors < ActiveRecord::Migration[8.1]
  def change
    add_column :monitors, :status_before_retirement, :string
  end
end
