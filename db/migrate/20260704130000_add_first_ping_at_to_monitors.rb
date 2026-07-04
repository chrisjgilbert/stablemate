class AddFirstPingAtToMonitors < ActiveRecord::Migration[8.1]
  # first_ping_at is the floor for uptime measurement (WU-10): a day entirely
  # before a monitor's first ping is no-data, never phantom-`up`. Best-effort
  # backfill from the earliest surviving PingEvent, falling back to the earliest
  # Incident start when a monitor's pings have all been pruned (an incident can
  # only open AFTER a real ping, so started_at is a valid floor) — otherwise a
  # long-down monitor whose pings are gone would keep NULL and its ongoing outage
  # would roll up as no-data instead of down. A genuinely never-pinged monitor has
  # neither, keeps NULL, and the rollup reads that as "no measured time".
  def up
    add_column :monitors, :first_ping_at, :datetime

    execute <<~SQL.squish
      UPDATE monitors m
      SET first_ping_at = COALESCE(
        (SELECT MIN(received_at) FROM ping_events WHERE ping_events.monitor_id = m.id),
        (SELECT MIN(started_at)  FROM incidents   WHERE incidents.monitor_id   = m.id)
      )
      WHERE EXISTS (SELECT 1 FROM ping_events WHERE ping_events.monitor_id = m.id)
         OR EXISTS (SELECT 1 FROM incidents   WHERE incidents.monitor_id   = m.id)
    SQL
  end

  def down
    remove_column :monitors, :first_ping_at
  end
end
