# What the gem's last sync SENT for each of the three settings it owns, beside
# what the monitor currently HAS. The pair is what lets a re-sync tell "the user
# tightened this in the UI" (stored != last synced) from "nobody has touched it"
# (stored == last synced) and stop reverting the user on every deploy — see
# Project::MonitorSync#gem_may_write?.
#
# Deliberately nullable with NO backfill: a monitor synced before this migration
# has nil here, and nil means "we don't know what the gem last sent", which the
# sync treats as "don't touch the user's values, just start remembering". Filling
# these in from the current columns would assert that today's value is the gem's
# — a lie for exactly the monitors the user has already overridden, and it would
# revert them once on the next deploy, which is the bug this exists to fix.
#
# The cost of that choice, stated plainly: a `recurring.yml` change already in
# flight when this deploys is NOT applied to a pre-existing monitor — it waits for
# the schedule to change again. On that first sync a divergence is equally
# consistent with "the user tightened this" and "the schedule changed", and we
# resolve it toward never overwriting the user. See the KNOWN LIMIT note on
# Project::MonitorSync#gem_may_write? and its pinning test.
class AddLastSyncedSettingsToMonitors < ActiveRecord::Migration[8.1]
  def change
    add_column :monitors, :last_synced_name, :string
    add_column :monitors, :last_synced_expected_interval_seconds, :integer
    add_column :monitors, :last_synced_grace_period_seconds, :integer
  end
end
