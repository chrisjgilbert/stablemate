class AddErrorToPingEventsAndIncidents < ActiveRecord::Migration[8.1]
  # Error notices (docs/specs/job-failure-details.md §4): a failure ping carries
  # the reported error text. On PingEvent it is the per-ping record (pruned with
  # the ping); on Incident it is the durable copy from the failure ping that
  # OPENED the incident, written once inside the same transaction, so the error
  # outlives PING_RETENTION and the email/banner never hunt for the opening
  # ping. Null for successes and missed-ping incidents — no backfill needed.
  def change
    add_column :ping_events, :error, :text
    add_column :incidents, :error, :text
  end
end
