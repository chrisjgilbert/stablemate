class AddFirstPingAtToMonitors < ActiveRecord::Migration[8.1]
  # first_ping_at is the floor for uptime measurement (WU-10): a day entirely
  # before a monitor's first ping is no-data, never phantom-`up`. Best-effort
  # backfill from surviving PingEvents (older ones may already be pruned); a
  # never-pinged monitor keeps NULL, which the rollup reads as "no measured time".
  def up
    add_column :monitors, :first_ping_at, :datetime

    execute <<~SQL.squish
      UPDATE monitors m
      SET first_ping_at = pe.min_received
      FROM (SELECT monitor_id, MIN(received_at) AS min_received FROM ping_events GROUP BY monitor_id) pe
      WHERE pe.monitor_id = m.id
    SQL
  end

  def down
    remove_column :monitors, :first_ping_at
  end
end
