# The raw schedule string a task's interval was derived from ("0 9 * * 1-5"),
# carried by the sync payload from day one and stored — but NOT acted on
# (v1-scope §6.3). V1 detection stays interval-based; storing the expression now
# means cron-aware detection later is a server-only upgrade with no gem release
# and no wire migration.
#
# Nullable, and nullable means something: a c.monitors entry declared with a bare
# interval has no schedule and sends none. The column means "the string the
# schedule was derived from", never a promise about when the job next runs.
class AddScheduleToMonitors < ActiveRecord::Migration[8.1]
  def change
    add_column :monitors, :schedule, :string
  end
end
