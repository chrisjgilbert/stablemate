# registration_key stops being an internal idempotency key and becomes the
# monitor's PUBLIC ADDRESS (v1-scope §0, §5.1), so every existing monitor needs
# one. This is a one-shot backfill, not a second ongoing writer:
# Project::MonitorSync remains the only code that assigns keys from here on.
#
# The key is `manual-<id>`, NOT derived from the monitor's name, and the namespace
# is the whole point (§8.1). A hand-created monitor called `daily_digest` given
# the key `daily_digest` would be ADOPTED by the next `stablemate:sync` that
# registers a Rails job of that name — two monitors silently becoming one, fed by
# both a shell cron and a Rails job, so killing the shell script leaves the
# monitor green. `manual-` is a namespace the gem never derives from a job class.
#
# The collision guard is still needed: `manual-7` is a string a human can type
# into recurring.yml, and the partial unique index on (project_id,
# registration_key) would raise RecordNotUnique, roll back the wrapping
# transaction and fail the deploy. Suffix until free instead.
#
# registration_key stays NULLABLE (§8): NOT NULL would cost ~215 test fixes and
# buys little while the sync is the only ongoing writer. That is why no constraint
# is added here — if one is ever added it must land in the same migration as a
# backfill, since it cannot be added while nulls remain.
class BackfillMonitorRegistrationKeys < ActiveRecord::Migration[8.1]
  # A migration-local model: the app's Monitoring::Monitor carries validations and
  # callbacks that will keep changing, and a backfill must run against the schema
  # as it was, not as the app is today.
  class Monitor < ActiveRecord::Base
    self.table_name = "monitors"
  end

  def up
    Monitor.where(registration_key: nil).find_each do |monitor|
      Monitor.where(id: monitor.id).update_all(registration_key: available_key_for(monitor))
    end
  end

  def down
    # Not reversible: once assigned, these keys are addresses that the gem and the
    # dashboard both use, and nothing distinguishes a backfilled key from one a
    # sync wrote afterwards. Re-nulling them would break live check-ins.
    raise ActiveRecord::IrreversibleMigration
  end

  private
    def available_key_for(monitor)
      base = "manual-#{monitor.id}"
      return base unless taken?(monitor, base)

      # Deliberately unbounded rather than "try twice and hope": each collision is
      # a key a human authored, so there is no bound on how many there could be.
      suffix = 2
      suffix += 1 while taken?(monitor, "#{base}-#{suffix}")
      "#{base}-#{suffix}"
    end

    # Uniqueness is per-project (that is the scope of the index), so a key only
    # collides with another monitor in the SAME project.
    def taken?(monitor, key)
      Monitor.where(project_id: monitor.project_id, registration_key: key).exists?
    end
end
