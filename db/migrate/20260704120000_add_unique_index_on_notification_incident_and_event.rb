class AddUniqueIndexOnNotificationIncidentAndEvent < ActiveRecord::Migration[8.1]
  # DB backstop for the transition-only alerting invariant: at most one `down` and
  # one `recovered` notification per incident. The Monitor operations already
  # serialise their transitions under `with_lock`, so this index is defence in
  # depth against any concurrent double-dispatch that slips the application guard.
  # Partial (incident-less notifications are not constrained — there are none in
  # V1, but the column is nullable).
  def change
    add_index :notifications, %i[incident_id event],
              unique: true,
              where: "incident_id IS NOT NULL",
              name: "index_notifications_on_incident_and_event"
  end
end
